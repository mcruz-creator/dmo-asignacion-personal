-- DMO · Asignación de personal
-- Ejecutar una sola vez en Supabase > SQL Editor.
-- Antes de ejecutar, reemplazar REEMPLAZAR_CON_TU_EMAIL por el correo del
-- primer administrador. Ese correo deberá ser el mismo usado para ingresar.

create extension if not exists pgcrypto;

create table if not exists public.responsibles (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.app_users (
  email text primary key,
  display_name text not null,
  role text not null check (role in ('rrhh','responsable','administrador')),
  responsible_id uuid references public.responsibles(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check ((role = 'responsable' and responsible_id is not null) or role <> 'responsable')
);

create table if not exists public.centers (
  id text primary key,
  code text not null,
  unit text not null,
  name text not null,
  type text not null check (type in ('Costo','Beneficio')),
  provisional boolean not null default false,
  responsible_id uuid references public.responsibles(id),
  active boolean not null default true,
  sort_order integer not null default 0
);

create table if not exists public.people (
  id text primary key,
  name text not null,
  start_date date not null,
  end_date date,
  responsible_id uuid not null references public.responsibles(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date is null or end_date >= start_date)
);

create table if not exists public.responsible_history (
  id uuid primary key default gen_random_uuid(),
  person_id text not null references public.people(id) on delete cascade,
  valid_from date not null,
  responsible_id uuid not null references public.responsibles(id),
  reason text,
  created_by text not null,
  created_at timestamptz not null default now(),
  unique(person_id, valid_from)
);

create table if not exists public.assignment_versions (
  id uuid primary key default gen_random_uuid(),
  person_id text not null references public.people(id) on delete cascade,
  valid_from date not null,
  valid_to date,
  created_by text not null,
  created_at timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  unique(person_id, valid_from)
);

create table if not exists public.assignment_lines (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.assignment_versions(id) on delete cascade,
  center_id text not null references public.centers(id),
  pct numeric(7,4) not null check (pct > 0 and pct <= 100),
  unique(version_id, center_id)
);

create table if not exists public.shared_confirmations (
  period date not null check (period = date_trunc('month', period)::date),
  person_id text not null references public.people(id) on delete cascade,
  center_id text not null references public.centers(id),
  version_id uuid not null references public.assignment_versions(id) on delete cascade,
  confirmed_by text not null,
  confirmed_at timestamptz not null default now(),
  primary key(period, person_id, center_id)
);

create table if not exists public.monthly_validations (
  period date not null check (period = date_trunc('month', period)::date),
  responsible_id uuid not null references public.responsibles(id),
  validated_by text not null,
  validated_at timestamptz not null default now(),
  primary key(period, responsible_id)
);

create table if not exists public.hr_validations (
  period date primary key check (period = date_trunc('month', period)::date),
  validated_by text not null,
  validated_at timestamptz not null default now()
);

create table if not exists public.audit_events (
  id bigint generated always as identity primary key,
  actor_email text not null,
  event_type text not null,
  description text not null,
  created_at timestamptz not null default now()
);

-- Momento en que el centro cambió de responsable: las confirmaciones anteriores no valen para meses abiertos.
alter table public.centers add column if not exists responsible_since timestamptz;

create or replace function public.current_email()
returns text language sql stable
as $$ select lower(coalesce(auth.jwt() ->> 'email','')) $$;

create or replace function public.current_app_user()
returns public.app_users language sql stable security definer
set search_path = public
as $$ select u from public.app_users u where lower(u.email)=public.current_email() and u.active limit 1 $$;

create or replace function public.current_role()
returns text language sql stable security definer
set search_path = public
as $$ select role from public.app_users where lower(email)=public.current_email() and active limit 1 $$;

create or replace function public.current_responsible_id()
returns uuid language sql stable security definer
set search_path = public
as $$ select responsible_id from public.app_users where lower(email)=public.current_email() and active limit 1 $$;

create or replace function public.is_active_user()
returns boolean language sql stable security definer
set search_path = public
as $$ select exists(select 1 from public.app_users where lower(email)=public.current_email() and active) $$;

create or replace function public.is_hr_or_admin()
returns boolean language sql stable security definer
set search_path = public
as $$ select coalesce(public.current_role() in ('rrhh','administrador'),false) $$;

-- Responsable principal de una persona en una fecha, según el historial.
create or replace function public.responsible_at(p_person_id text, p_date date)
returns uuid language sql stable security definer set search_path=public
as $$
  select coalesce(
    (select h.responsible_id from public.responsible_history h
      where h.person_id=p_person_id and h.valid_from<=p_date
      order by h.valid_from desc limit 1),
    (select p.responsible_id from public.people p where p.id=p_person_id))
$$;

-- Responsable de la persona en un mes: el vigente al cierre del mes (o al día de la baja).
create or replace function public.responsible_in_month(p_person_id text, p_month date)
returns uuid language sql stable security definer set search_path=public
as $$
  select public.responsible_at(p.id, least(coalesce(p.end_date,m.e),m.e))
  from public.people p
  cross join (select (date_trunc('month',p_month)+interval '1 month -1 day')::date e) m
  where p.id=p_person_id
$$;

-- Un mes está cerrado cuando RRHH validó la nómina. p_to null = sin límite.
create or replace function public.assert_open(p_from date, p_to date)
returns void language plpgsql security definer set search_path=public
as $$
declare v_closed date;
begin
  select min(period) into v_closed from public.hr_validations
  where period>=date_trunc('month',p_from)::date and (p_to is null or period<=p_to);
  if v_closed is not null then
    raise exception 'El mes % está cerrado. Para modificarlo, RRHH o el administrador deben reabrirlo desde Cierre mensual.', to_char(v_closed,'MM/YYYY');
  end if;
end $$;

revoke all on function public.responsible_at(text,date) from public;
revoke all on function public.responsible_in_month(text,date) from public;
revoke all on function public.assert_open(date,date) from public;

create or replace function public.can_see_person(person_key text)
returns boolean language sql stable security definer
set search_path = public
as $$
  select public.is_hr_or_admin()
  or exists (
    select 1 from public.people p
    where p.id=person_key and p.responsible_id=public.current_responsible_id()
  )
  or exists (
    select 1 from public.responsible_history h
    where h.person_id=person_key and h.responsible_id=public.current_responsible_id()
  )
  or exists (
    select 1
    from public.assignment_versions v
    join public.assignment_lines l on l.version_id=v.id
    join public.centers c on c.id=l.center_id
    where v.person_id=person_key and c.responsible_id=public.current_responsible_id()
  )
$$;

alter table public.responsibles enable row level security;
alter table public.app_users enable row level security;
alter table public.centers enable row level security;
alter table public.people enable row level security;
alter table public.responsible_history enable row level security;
alter table public.assignment_versions enable row level security;
alter table public.assignment_lines enable row level security;
alter table public.shared_confirmations enable row level security;
alter table public.monthly_validations enable row level security;
alter table public.hr_validations enable row level security;
alter table public.audit_events enable row level security;

drop policy if exists responsible_read on public.responsibles;
create policy responsible_read on public.responsibles for select to authenticated using (public.is_active_user());
drop policy if exists responsible_manage on public.responsibles;
create policy responsible_manage on public.responsibles for all to authenticated using (public.is_hr_or_admin()) with check (public.is_hr_or_admin());

drop policy if exists app_user_read on public.app_users;
create policy app_user_read on public.app_users for select to authenticated
using (lower(email)=public.current_email() or public.is_hr_or_admin());
drop policy if exists app_user_manage on public.app_users;
-- RRHH puede gestionar usuarios, pero no crear, modificar ni desactivar administradores.
create policy app_user_manage on public.app_users for all to authenticated
using (public.current_role()='administrador' or (public.current_role()='rrhh' and role<>'administrador'))
with check (public.current_role()='administrador' or (public.current_role()='rrhh' and role<>'administrador'));

drop policy if exists center_read on public.centers;
create policy center_read on public.centers for select to authenticated using (public.is_active_user());
drop policy if exists center_manage on public.centers;
create policy center_manage on public.centers for all to authenticated using (public.is_hr_or_admin()) with check (public.is_hr_or_admin());

drop policy if exists people_read on public.people;
create policy people_read on public.people for select to authenticated using (public.can_see_person(id));
drop policy if exists people_manage on public.people;
create policy people_manage on public.people for all to authenticated using (public.is_hr_or_admin()) with check (public.is_hr_or_admin());

drop policy if exists responsible_history_read on public.responsible_history;
create policy responsible_history_read on public.responsible_history for select to authenticated using (public.can_see_person(person_id));
drop policy if exists responsible_history_manage on public.responsible_history;
create policy responsible_history_manage on public.responsible_history for all to authenticated using (public.is_hr_or_admin()) with check (public.is_hr_or_admin());

drop policy if exists assignment_version_read on public.assignment_versions;
create policy assignment_version_read on public.assignment_versions for select to authenticated using (public.can_see_person(person_id));
drop policy if exists assignment_line_read on public.assignment_lines;
create policy assignment_line_read on public.assignment_lines for select to authenticated
using (exists(select 1 from public.assignment_versions v where v.id=version_id and public.can_see_person(v.person_id)));

drop policy if exists shared_confirmation_read on public.shared_confirmations;
create policy shared_confirmation_read on public.shared_confirmations for select to authenticated using (public.can_see_person(person_id));
-- Las confirmaciones se registran sólo con confirm_shared, que controla el mes cerrado.
drop policy if exists shared_confirmation_write on public.shared_confirmations;

drop policy if exists monthly_validation_read on public.monthly_validations;
create policy monthly_validation_read on public.monthly_validations for select to authenticated using (public.is_active_user());
drop policy if exists monthly_validation_write on public.monthly_validations;
create policy monthly_validation_write on public.monthly_validations for all to authenticated
using (public.current_role()='administrador')
with check (public.current_role()='administrador');

drop policy if exists hr_validation_read on public.hr_validations;
create policy hr_validation_read on public.hr_validations for select to authenticated using (public.is_active_user());
-- El cierre del mes se registra sólo con close_month / reopen_month.
drop policy if exists hr_validation_write on public.hr_validations;

drop policy if exists audit_read on public.audit_events;
create policy audit_read on public.audit_events for select to authenticated using (public.is_hr_or_admin());
drop policy if exists audit_insert on public.audit_events;
create policy audit_insert on public.audit_events for insert to authenticated with check (actor_email=public.current_email() and public.is_active_user());

-- Guarda la asignación desde un mes. Rige hasta la próxima versión o hasta que la persona cambie de
-- responsable. No hace nada si no hay cambios; si los hay, sólo reinicia la validación de los
-- responsables afectados en los meses alcanzados. Rechaza cambios que alcancen un mes cerrado.
create or replace function public.save_assignment(
  p_person_id text,
  p_valid_from date,
  p_lines jsonb
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  v_person public.people;
  v_from date := date_trunc('month',p_valid_from)::date;
  v_mend date := (date_trunc('month',p_valid_from)+interval '1 month -1 day')::date;
  v_owner uuid;
  v_total numeric;
  v_prev uuid;
  v_next date;
  v_cut date;
  v_stop date;
  v_cont uuid;
  v_version uuid;
  v_keep jsonb;
  v_affected uuid[];
begin
  select * into v_person from public.people where id=p_person_id;
  if not found then raise exception 'Persona inexistente'; end if;
  if p_valid_from is null then raise exception 'Indicá desde qué mes rige la asignación'; end if;
  if v_from<date_trunc('month',v_person.start_date)::date then
    raise exception 'La asignación no puede regir antes del alta (%)', to_char(v_person.start_date,'DD/MM/YYYY');
  end if;
  if v_person.end_date is not null and v_from>v_person.end_date then
    raise exception 'La asignación no puede regir después de la baja (%)', to_char(v_person.end_date,'DD/MM/YYYY');
  end if;
  v_owner := public.responsible_in_month(p_person_id,v_from);
  if not public.is_hr_or_admin() and v_owner is distinct from public.current_responsible_id() then
    raise exception 'No tiene permiso para asignar esta persona en ese mes';
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines)=0 then
    raise exception 'La asignación debe sumar 100%%';
  end if;
  if exists(select 1 from jsonb_array_elements(p_lines) x where coalesce(x->>'center_id','')='') then
    raise exception 'Elegí un centro en cada fila con porcentaje';
  end if;
  select coalesce(sum((x->>'pct')::numeric),0) into v_total from jsonb_array_elements(p_lines) x;
  if abs(v_total-100) > 0.0001 then raise exception 'La asignación debe sumar 100%%'; end if;
  if exists(select 1 from jsonb_array_elements(p_lines) x group by x->>'center_id' having count(*)>1) then
    raise exception 'No se puede repetir un centro';
  end if;

  -- Versión que rige hoy en ese mes.
  select id into v_prev from public.assignment_versions
    where person_id=p_person_id and valid_from<=v_mend and (valid_to is null or valid_to>=v_mend)
    order by valid_from desc limit 1;

  -- Centros cuyo porcentaje cambia (incluye los que se agregan o se quitan).
  select coalesce(array_agg(distinct c.responsible_id) filter (where c.responsible_id is not null),'{}') into v_affected
  from (select center_id, pct from public.assignment_lines where version_id=v_prev) o
  full join (select x->>'center_id' center_id, round((x->>'pct')::numeric,4) pct from jsonb_array_elements(p_lines) x) n
    on n.center_id=o.center_id
  join public.centers c on c.id=coalesce(n.center_id,o.center_id)
  where o.pct is distinct from n.pct;
  if v_prev is not null and not exists(
    select 1
    from (select center_id, pct from public.assignment_lines where version_id=v_prev) o
    full join (select x->>'center_id' center_id, round((x->>'pct')::numeric,4) pct from jsonb_array_elements(p_lines) x) n
      on n.center_id=o.center_id
    where o.pct is distinct from n.pct
  ) then
    return v_prev;
  end if;

  -- Hasta dónde rige: la próxima versión o el próximo cambio de responsable.
  select min(valid_from) into v_next from public.assignment_versions
    where person_id=p_person_id and valid_from>v_mend;
  select min(date_trunc('month',h.valid_from)::date) into v_cut from public.responsible_history h
    where h.person_id=p_person_id and h.valid_from>v_mend and h.responsible_id is distinct from v_owner;
  v_stop := least(v_next,v_cut);
  perform public.assert_open(v_from, v_stop-1);

  -- Si la persona pasa a otro responsable antes de la próxima versión, sus meses conservan la asignación anterior.
  if v_prev is not null and v_cut is not null and (v_next is null or v_cut<v_next) then
    insert into public.assignment_versions(person_id,valid_from,valid_to,created_by)
      values(p_person_id,v_cut,v_next-1,public.current_email()) returning id into v_cont;
    insert into public.assignment_lines(version_id,center_id,pct)
      select v_cont,center_id,pct from public.assignment_lines where version_id=v_prev;
    update public.shared_confirmations set version_id=v_cont
      where person_id=p_person_id and version_id=v_prev and period>=v_cut;
  end if;

  update public.assignment_versions
    set valid_to=v_from-1
    where person_id=p_person_id and valid_from<v_from and (valid_to is null or valid_to>=v_from);
  -- Conserva las confirmaciones de la versión del mismo mes para reubicar las de porcentajes sin cambios.
  select coalesce(jsonb_agg(jsonb_build_object('period',sc.period,'center_id',sc.center_id,'pct',l.pct,'confirmed_by',sc.confirmed_by,'confirmed_at',sc.confirmed_at)),'[]'::jsonb) into v_keep
    from public.shared_confirmations sc
    join public.assignment_versions v on v.id=sc.version_id and v.person_id=p_person_id and v.valid_from between v_from and v_mend
    join public.assignment_lines l on l.version_id=v.id and l.center_id=sc.center_id;
  delete from public.assignment_versions where person_id=p_person_id and valid_from between v_from and v_mend;
  insert into public.assignment_versions(person_id,valid_from,valid_to,created_by)
    values(p_person_id,v_from,v_stop-1,public.current_email()) returning id into v_version;
  insert into public.assignment_lines(version_id,center_id,pct)
    select v_version,x->>'center_id',(x->>'pct')::numeric from jsonb_array_elements(p_lines) x;
  insert into public.shared_confirmations(period,person_id,center_id,version_id,confirmed_by,confirmed_at)
    select (k->>'period')::date,p_person_id,k->>'center_id',v_version,k->>'confirmed_by',(k->>'confirmed_at')::timestamptz
    from jsonb_array_elements(v_keep) k
    join public.assignment_lines nl on nl.version_id=v_version and nl.center_id=k->>'center_id' and nl.pct=(k->>'pct')::numeric
    on conflict do nothing;
  delete from public.monthly_validations
    where period>=v_from and (v_stop is null or period<v_stop)
      and responsible_id=any(v_affected||v_owner);
  insert into public.audit_events(actor_email,event_type,description)
    values(public.current_email(),'assignment','Asignación actualizada para '||p_person_id||' desde '||to_char(v_from,'MM/YYYY'));
  return v_version;
end $$;

revoke all on function public.save_assignment(text,date,jsonb) from public;
grant execute on function public.save_assignment(text,date,jsonb) to authenticated;

-- Una dedicación compartida sigue confirmada en los meses siguientes mientras su porcentaje no cambie
-- y el centro no cambie de responsable (salvo en meses ya cerrados).
create or replace function public.shared_confirmed(p_person_id text,p_center_id text,p_version_id uuid,p_month date)
returns boolean language sql stable security definer set search_path=public
as $$
  select exists(
    select 1
    from public.assignment_versions cur
    join public.centers c on c.id=p_center_id
    join public.people p on p.id=p_person_id
    join public.assignment_lines curl on curl.version_id=cur.id and curl.center_id=p_center_id
    join public.shared_confirmations sc on sc.person_id=p_person_id and sc.center_id=p_center_id and sc.period<=p_month
    join public.assignment_versions cv on cv.id=sc.version_id and cv.person_id=p_person_id and cv.valid_from<=cur.valid_from
    join public.assignment_lines cl on cl.version_id=cv.id and cl.center_id=p_center_id and cl.pct=curl.pct
    where cur.id=p_version_id
      -- Tras un reingreso no se arrastran confirmaciones del período anterior.
      and (cv.valid_from>=date_trunc('month',p.start_date)::date or cur.valid_from<date_trunc('month',p.start_date)::date)
      and (c.responsible_since is null or sc.confirmed_at>=c.responsible_since
        or exists(select 1 from public.hr_validations hv where hv.period=date_trunc('month',p_month)::date))
      and not exists(
        select 1 from public.assignment_versions iv
        left join public.assignment_lines il on il.version_id=iv.id and il.center_id=p_center_id
        where iv.person_id=p_person_id and iv.valid_from>cv.valid_from and iv.valid_from<=cur.valid_from
          and il.pct is distinct from curl.pct
      )
  )
$$;

revoke all on function public.shared_confirmed(text,text,uuid,date) from public;

create or replace function public.validate_responsible_month(p_period date)
returns void language plpgsql security definer set search_path=public
as $$
declare
  v_rid uuid := public.current_responsible_id();
  v_month date := date_trunc('month',p_period)::date;
  v_end date := (date_trunc('month',p_period)+interval '1 month -1 day')::date;
begin
  if public.current_role()<>'responsable' or v_rid is null then
    raise exception 'Sólo un responsable habilitado puede validar su mes';
  end if;
  perform public.assert_open(v_month, v_month);
  if exists (
    select 1 from public.people p
    left join lateral (
      select v.id from public.assignment_versions v
      where v.person_id=p.id and v.valid_from<=least(coalesce(p.end_date,v_end),v_end)
        and (v.valid_to is null or v.valid_to>=least(coalesce(p.end_date,v_end),v_end))
      order by v.valid_from desc limit 1
    ) v on true
    left join public.assignment_lines l on l.version_id=v.id
    where public.responsible_in_month(p.id,v_month)=v_rid and p.start_date<=v_end and (p.end_date is null or p.end_date>=v_month)
    group by p.id,v.id
    having v.id is null or abs(coalesce(sum(l.pct),0)-100)>0.0001
  ) then raise exception 'Hay personas propias cuya asignación no suma 100%%'; end if;
  if exists (
    select 1 from public.people p
    join lateral (
      select v.id from public.assignment_versions v
      where v.person_id=p.id and v.valid_from<=least(coalesce(p.end_date,v_end),v_end)
        and (v.valid_to is null or v.valid_to>=least(coalesce(p.end_date,v_end),v_end))
      order by v.valid_from desc limit 1
    ) v on true
    cross join lateral (select public.responsible_in_month(p.id,v_month) owner) o
    join public.assignment_lines l on l.version_id=v.id
    join public.centers c on c.id=l.center_id
    where p.start_date<=v_end and (p.end_date is null or p.end_date>=v_month)
      and ((o.owner=v_rid and c.responsible_id is not null and c.responsible_id<>v_rid)
        or (o.owner<>v_rid and c.responsible_id=v_rid))
      and not public.shared_confirmed(p.id,c.id,v.id,v_month)
  ) then raise exception 'Hay dedicaciones compartidas sin confirmar'; end if;
  insert into public.monthly_validations(period,responsible_id,validated_by)
  values(v_month,v_rid,public.current_email())
  on conflict(period,responsible_id) do update set validated_by=excluded.validated_by,validated_at=now();
  insert into public.audit_events(actor_email,event_type,description)
  values(public.current_email(),'monthly_validation','Validación mensual '||to_char(v_month,'YYYY-MM'));
end $$;

revoke all on function public.validate_responsible_month(date) from public;
grant execute on function public.validate_responsible_month(date) to authenticated;

create or replace function public.clear_operational_data()
returns void language plpgsql security definer set search_path=public
as $$
begin
  if public.current_role()<>'administrador' then raise exception 'Sólo el administrador puede vaciar la prueba'; end if;
  delete from public.hr_validations where true;
  delete from public.monthly_validations where true;
  delete from public.shared_confirmations where true;
  update public.centers set responsible_id=null where responsible_id is not null;
  delete from public.app_users where role='responsable';
  delete from public.people where true;
  delete from public.responsibles where true;
  insert into public.audit_events(actor_email,event_type,description)
  values(public.current_email(),'clear_test','Se vaciaron los datos operativos para realizar la carga real');
end $$;

revoke all on function public.clear_operational_data() from public;
grant execute on function public.clear_operational_data() to authenticated;

-- Altas y cambios de fechas: se rechazan si alcanzan un mes cerrado y reinician sólo la validación
-- de los responsables vinculados a esa persona en los meses alcanzados.
create or replace function public.invalidate_people_control()
returns trigger language plpgsql security definer set search_path=public
as $$
declare
  far constant date := '9999-12-31';
  v_lo date;
  v_hi date;
begin
  if tg_op='INSERT' then
    v_lo := new.start_date; v_hi := new.end_date;
  elsif (old.start_date,old.end_date) is not distinct from (new.start_date,new.end_date) then
    return new;
  elsif old.end_date is not null and new.end_date is null and new.start_date>old.end_date then
    -- Reingreso: el período anterior deja de contar; sólo se controla el nuevo.
    v_lo := new.start_date; v_hi := null;
  else
    v_lo := far; v_hi := '0001-01-01';
    if old.start_date is distinct from new.start_date then
      v_lo := least(v_lo,old.start_date,new.start_date); v_hi := greatest(v_hi,old.start_date,new.start_date);
    end if;
    if old.end_date is distinct from new.end_date then
      v_lo := least(v_lo,coalesce(old.end_date,far),coalesce(new.end_date,far));
      v_hi := greatest(v_hi,coalesce(old.end_date,far),coalesce(new.end_date,far));
    end if;
    if v_hi=far then v_hi := null; end if;
  end if;
  perform public.assert_open(v_lo, v_hi);
  delete from public.monthly_validations mv
    where mv.period>=date_trunc('month',v_lo)::date and (v_hi is null or mv.period<=v_hi)
      and (mv.responsible_id=new.responsible_id
        or mv.responsible_id in (select h.responsible_id from public.responsible_history h where h.person_id=new.id)
        or mv.responsible_id in (
          select c.responsible_id from public.assignment_versions v
          join public.assignment_lines l on l.version_id=v.id
          join public.centers c on c.id=l.center_id
          where v.person_id=new.id));
  return new;
end $$;

drop trigger if exists people_invalidate_control on public.people;
create trigger people_invalidate_control before insert or update of start_date,end_date on public.people
for each row execute function public.invalidate_people_control();

-- Cambiar el responsable de un centro: las confirmaciones anteriores quedan para los meses cerrados;
-- en los abiertos debe confirmar el nuevo responsable. Se reinician las validaciones abiertas afectadas.
create or replace function public.invalidate_center_control()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  if old.responsible_id is distinct from new.responsible_id then
    new.responsible_since := now();
    delete from public.monthly_validations mv
      where mv.period not in (select hv.period from public.hr_validations hv)
        and (mv.responsible_id in (old.responsible_id,new.responsible_id)
          or mv.responsible_id in (
            select p.responsible_id from public.assignment_lines l
            join public.assignment_versions v on v.id=l.version_id
            join public.people p on p.id=v.person_id
            where l.center_id=new.id)
          or mv.responsible_id in (
            select h.responsible_id from public.assignment_lines l
            join public.assignment_versions v on v.id=l.version_id
            join public.responsible_history h on h.person_id=v.person_id
            where l.center_id=new.id));
  end if;
  return new;
end $$;

drop trigger if exists center_invalidate_control on public.centers;
create trigger center_invalidate_control before update of responsible_id on public.centers
for each row execute function public.invalidate_center_control();

-- Cambios en el historial de responsables: se rechazan si alcanzan un mes cerrado y reinician la
-- validación del responsable anterior y del nuevo en los meses alcanzados.
create or replace function public.responsible_history_control()
returns trigger language plpgsql security definer set search_path=public
as $$
declare
  v_person text := coalesce(new.person_id,old.person_id);
  v_lo date;
  v_hi date;
begin
  if tg_op='DELETE' then
    if not exists(select 1 from public.people where id=old.person_id) then return old; end if;
    v_lo := old.valid_from;
  elsif tg_op='UPDATE' then
    if (old.valid_from,old.responsible_id) is not distinct from (new.valid_from,new.responsible_id) then return new; end if;
    v_lo := least(old.valid_from,new.valid_from);
  else
    v_lo := new.valid_from;
  end if;
  select min(h.valid_from)-1 into v_hi from public.responsible_history h
    where h.person_id=v_person and h.valid_from>greatest(coalesce(old.valid_from,new.valid_from),coalesce(new.valid_from,old.valid_from));
  perform public.assert_open(v_lo, v_hi);
  delete from public.monthly_validations mv
    where mv.period>=date_trunc('month',v_lo)::date and (v_hi is null or mv.period<=v_hi)
      and (mv.responsible_id in (new.responsible_id,old.responsible_id)
        or mv.responsible_id=public.responsible_at(v_person,v_lo)
        or mv.responsible_id in (select p.responsible_id from public.people p where p.id=v_person));
  return coalesce(new,old);
end $$;

drop trigger if exists responsible_history_control on public.responsible_history;
create trigger responsible_history_control before insert or update or delete on public.responsible_history
for each row execute function public.responsible_history_control();

-- Alta de una persona, o reingreso del mismo legajo si estaba de baja. Todo en una sola operación.
create or replace function public.register_hire(p_id text, p_name text, p_start date, p_responsible_id uuid)
returns text language plpgsql security definer set search_path=public
as $$
declare
  v_id text := trim(coalesce(p_id,''));
  v_name text := trim(coalesce(p_name,''));
  v_old public.people;
begin
  if not public.is_hr_or_admin() then raise exception 'Sólo RRHH o el administrador pueden registrar ingresos'; end if;
  if v_id='' or v_name='' or p_start is null or p_responsible_id is null then raise exception 'Completá todos los datos.'; end if;
  if not exists(select 1 from public.responsibles where id=p_responsible_id and active) then
    raise exception 'El responsable elegido no existe o no está activo.';
  end if;
  select * into v_old from public.people where id=v_id for update;
  if not found then
    insert into public.people(id,name,start_date,responsible_id) values(v_id,v_name,p_start,p_responsible_id);
    insert into public.responsible_history(person_id,valid_from,responsible_id,created_by)
      values(v_id,p_start,p_responsible_id,public.current_email());
    insert into public.audit_events(actor_email,event_type,description)
      values(public.current_email(),'hire','Alta de '||v_name||' ('||v_id||') desde '||to_char(p_start,'DD/MM/YYYY'));
    return 'alta';
  end if;
  if v_old.end_date is null then
    raise exception 'Ya existe una persona activa con el legajo % (%).', v_id, v_old.name;
  end if;
  if p_start<=v_old.end_date then
    raise exception 'La fecha de reingreso debe ser posterior a la baja anterior (%).', to_char(v_old.end_date,'DD/MM/YYYY');
  end if;
  -- Reingreso: se reactiva el mismo legajo. Las asignaciones anteriores quedan cerradas a la fecha de
  -- baja; el nuevo período necesita su propia asignación.
  update public.assignment_versions set valid_to=greatest(valid_from,v_old.end_date)
    where person_id=v_id and (valid_to is null or valid_to>v_old.end_date);
  update public.people set name=v_name,start_date=p_start,end_date=null,responsible_id=p_responsible_id,active=true,updated_at=now()
    where id=v_id;
  insert into public.responsible_history(person_id,valid_from,responsible_id,reason,created_by)
    values(v_id,p_start,p_responsible_id,'Reingreso',public.current_email())
    on conflict(person_id,valid_from) do update set responsible_id=excluded.responsible_id,reason=excluded.reason,created_by=excluded.created_by;
  insert into public.audit_events(actor_email,event_type,description)
    values(public.current_email(),'rehire','Reingreso de '||v_name||' ('||v_id||') desde '||to_char(p_start,'DD/MM/YYYY')||'; baja anterior '||to_char(v_old.end_date,'DD/MM/YYYY'));
  return 'reingreso';
end $$;

revoke all on function public.register_hire(text,text,date,uuid) from public;
grant execute on function public.register_hire(text,text,date,uuid) to authenticated;

-- Cambio de responsable principal desde un mes. Los meses anteriores conservan el responsable que tenían.
create or replace function public.change_responsible(p_person_id text, p_from date, p_responsible_id uuid, p_reason text)
returns void language plpgsql security definer set search_path=public
as $$
declare
  v_person public.people;
  v_from date;
begin
  if not public.is_hr_or_admin() then raise exception 'Sólo RRHH o el administrador pueden cambiar el responsable'; end if;
  if p_from is null or p_responsible_id is null then raise exception 'Indicá el responsable y desde qué mes.'; end if;
  select * into v_person from public.people where id=p_person_id for update;
  if not found then raise exception 'Persona inexistente'; end if;
  if not exists(select 1 from public.responsibles where id=p_responsible_id and active) then
    raise exception 'El responsable elegido no existe o no está activo.';
  end if;
  v_from := greatest(date_trunc('month',p_from)::date, v_person.start_date);
  if v_person.end_date is not null and v_from>v_person.end_date then
    raise exception 'La persona ya estaba de baja en ese mes.';
  end if;
  if public.responsible_in_month(p_person_id,v_from) is not distinct from p_responsible_id then
    raise exception 'Ese responsable ya es el responsable principal en %.', to_char(v_from,'MM/YYYY');
  end if;
  insert into public.responsible_history(person_id,valid_from,responsible_id,reason,created_by)
    values(p_person_id,v_from,p_responsible_id,nullif(trim(coalesce(p_reason,'')),''),public.current_email())
    on conflict(person_id,valid_from) do update set responsible_id=excluded.responsible_id,reason=excluded.reason,created_by=excluded.created_by,created_at=now();
  update public.people
    set responsible_id=(select h.responsible_id from public.responsible_history h where h.person_id=p_person_id order by h.valid_from desc limit 1),
        updated_at=now()
    where id=p_person_id;
  insert into public.audit_events(actor_email,event_type,description)
    values(public.current_email(),'responsible_change','Cambio de responsable de '||v_person.name||' desde '||to_char(v_from,'MM/YYYY')||': '||(select name from public.responsibles where id=p_responsible_id));
end $$;

revoke all on function public.change_responsible(text,date,uuid,text) from public;
grant execute on function public.change_responsible(text,date,uuid,text) to authenticated;

-- Confirmación de una dedicación recibida para el mes (sólo el responsable del centro, RRHH o administrador).
create or replace function public.confirm_shared(p_period date, p_person_id text, p_center_id text)
returns void language plpgsql security definer set search_path=public
as $$
declare
  v_month date := date_trunc('month',p_period)::date;
  v_end date := (date_trunc('month',p_period)+interval '1 month -1 day')::date;
  v_person public.people;
  v_center public.centers;
  v_version uuid;
begin
  select * into v_center from public.centers where id=p_center_id;
  if not found then raise exception 'Centro inexistente'; end if;
  if not public.is_hr_or_admin() and v_center.responsible_id is distinct from public.current_responsible_id() then
    raise exception 'Sólo el responsable del centro puede confirmar esta dedicación';
  end if;
  perform public.assert_open(v_month, v_month);
  select * into v_person from public.people where id=p_person_id;
  if not found or v_person.start_date>v_end or (v_person.end_date is not null and v_person.end_date<v_month) then
    raise exception 'La persona no está activa en ese mes';
  end if;
  select v.id into v_version from public.assignment_versions v
    where v.person_id=p_person_id
      and v.valid_from<=least(coalesce(v_person.end_date,v_end),v_end)
      and (v.valid_to is null or v.valid_to>=least(coalesce(v_person.end_date,v_end),v_end))
    order by v.valid_from desc limit 1;
  if v_version is null or not exists(select 1 from public.assignment_lines where version_id=v_version and center_id=p_center_id) then
    raise exception 'La asignación de ese mes ya no incluye este centro. Actualizá la pantalla.';
  end if;
  insert into public.shared_confirmations(period,person_id,center_id,version_id,confirmed_by,confirmed_at)
    values(v_month,p_person_id,p_center_id,v_version,public.current_email(),now())
    on conflict(period,person_id,center_id) do update set version_id=excluded.version_id,confirmed_by=excluded.confirmed_by,confirmed_at=now();
  insert into public.audit_events(actor_email,event_type,description)
    values(public.current_email(),'shared_confirmation','Confirmación de '||v_person.name||' en '||v_center.name||' para '||to_char(v_month,'YYYY-MM'));
end $$;

revoke all on function public.confirm_shared(date,text,text) from public;
grant execute on function public.confirm_shared(date,text,text) to authenticated;

-- RRHH valida la nómina y cierra el mes. Requiere que todos los responsables del mes hayan validado.
create or replace function public.close_month(p_period date)
returns void language plpgsql security definer set search_path=public
as $$
declare
  v_month date := date_trunc('month',p_period)::date;
  v_end date := (date_trunc('month',p_period)+interval '1 month -1 day')::date;
  v_pending text;
begin
  if not public.is_hr_or_admin() then raise exception 'Sólo RRHH o el administrador pueden cerrar el mes'; end if;
  if exists(select 1 from public.hr_validations where period=v_month) then return; end if;
  with act as (
    select p.id, least(coalesce(p.end_date,v_end),v_end) d from public.people p
    where p.start_date<=v_end and (p.end_date is null or p.end_date>=v_month)
  ), ver as (
    select a.id, a.d, (
      select v.id from public.assignment_versions v
      where v.person_id=a.id and v.valid_from<=a.d and (v.valid_to is null or v.valid_to>=a.d)
      order by v.valid_from desc limit 1) vid
    from act a
  ), reps as (
    select public.responsible_at(ver.id,ver.d) rid from ver
    union
    select c.responsible_id from ver
    join public.assignment_lines l on l.version_id=ver.vid
    join public.centers c on c.id=l.center_id
    where c.responsible_id is not null
  )
  select string_agg(r.name,', ' order by r.name) into v_pending
  from reps join public.responsibles r on r.id=reps.rid and r.active
  where not exists(select 1 from public.monthly_validations mv where mv.period=v_month and mv.responsible_id=reps.rid);
  if v_pending is not null then
    raise exception 'Todavía no validaron el mes: %', v_pending;
  end if;
  insert into public.hr_validations(period,validated_by) values(v_month,public.current_email());
  insert into public.audit_events(actor_email,event_type,description)
    values(public.current_email(),'hr_validation','RRHH validó la nómina y cerró '||to_char(v_month,'YYYY-MM'));
end $$;

revoke all on function public.close_month(date) from public;
grant execute on function public.close_month(date) to authenticated;

-- Reabre un mes cerrado para permitir correcciones.
create or replace function public.reopen_month(p_period date)
returns void language plpgsql security definer set search_path=public
as $$
declare v_month date := date_trunc('month',p_period)::date;
begin
  if not public.is_hr_or_admin() then raise exception 'Sólo RRHH o el administrador pueden reabrir el mes'; end if;
  delete from public.hr_validations where period=v_month;
  if found then
    insert into public.audit_events(actor_email,event_type,description)
      values(public.current_email(),'hr_reopen','Se reabrió '||to_char(v_month,'YYYY-MM'));
  end if;
end $$;

revoke all on function public.reopen_month(date) from public;
grant execute on function public.reopen_month(date) to authenticated;

grant select,insert,update,delete on public.responsibles,public.app_users,public.centers,public.people,
  public.responsible_history,public.assignment_versions,public.assignment_lines,public.shared_confirmations,
  public.monthly_validations,public.hr_validations,public.audit_events to authenticated;
grant usage,select on sequence public.audit_events_id_seq to authenticated;

-- Acceso con correo y contraseña. No se envían correos: administradores y RRHH
-- asignan una contraseña inicial y cada usuario la reemplaza en su primer ingreso.
alter table public.app_users add column if not exists must_change_password boolean not null default false;
alter table public.app_users add column if not exists password_set_at timestamptz;

-- Uso interno: crea la cuenta de Supabase Auth o actualiza su contraseña.
create or replace function public.write_auth_password(p_email text, p_password text, p_sign_out boolean)
returns void language plpgsql security definer set search_path=public, extensions
as $$
declare uid uuid; addr text := lower(trim(p_email));
begin
  if length(coalesce(p_password,''))<8 then
    raise exception 'La contraseña debe tener al menos 8 caracteres.';
  end if;
  select id into uid from auth.users where lower(email)=addr limit 1;
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
      raw_app_meta_data,raw_user_meta_data,created_at,updated_at,
      confirmation_token,recovery_token,email_change_token_new,email_change,
      email_change_token_current,phone_change,phone_change_token,reauthentication_token)
    values('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated',addr,
      crypt(p_password,gen_salt('bf')),now(),
      '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now(),'','','','','','','','');
    insert into auth.identities(id,user_id,provider_id,provider,identity_data,last_sign_in_at,created_at,updated_at)
    values(gen_random_uuid(),uid,uid::text,'email',
      jsonb_build_object('sub',uid::text,'email',addr,'email_verified',true),now(),now(),now());
  else
    update auth.users set encrypted_password=crypt(p_password,gen_salt('bf')),
      email_confirmed_at=coalesce(email_confirmed_at,now()),updated_at=now()
    where id=uid;
    if p_sign_out then
      delete from auth.sessions where user_id=uid;
    end if;
  end if;
  update public.app_users set password_set_at=now() where email=addr;
end $$;
revoke all on function public.write_auth_password(text,text,boolean) from public, anon, authenticated;

-- Administradores y RRHH asignan contraseñas iniciales. RRHH no puede tocar administradores.
create or replace function public.set_user_password(target_email text, new_password text)
returns void language plpgsql security definer set search_path=public
as $$
declare caller text := public.current_role(); target public.app_users; own boolean;
begin
  if coalesce(caller,'') not in ('administrador','rrhh') then
    raise exception 'No tenés permiso para asignar contraseñas.';
  end if;
  select * into target from public.app_users where email=lower(trim(target_email));
  if not found then
    raise exception 'Ese correo no está habilitado en la aplicación.';
  end if;
  if caller='rrhh' and target.role='administrador' then
    raise exception 'RRHH no puede cambiar la contraseña de un administrador.';
  end if;
  own := target.email=public.current_email();
  perform public.write_auth_password(target.email,new_password,not own);
  update public.app_users set must_change_password=not own where email=target.email;
  insert into public.audit_events(actor_email,event_type,description)
  values(public.current_email(),'access','Contraseña asignada a '||target.email);
end $$;
revoke all on function public.set_user_password(text,text) from public, anon;
grant execute on function public.set_user_password(text,text) to authenticated;

-- Cada usuario cambia su propia contraseña. En el primer ingreso no se pide la actual.
create or replace function public.change_my_password(current_password text, new_password text)
returns void language plpgsql security definer set search_path=public, extensions
as $$
declare u public.app_users; hash text;
begin
  select * into u from public.app_users where email=public.current_email() and active;
  if not found then
    raise exception 'Tu usuario no está habilitado.';
  end if;
  select encrypted_password into hash from auth.users where id=auth.uid();
  if not u.must_change_password and coalesce(hash,'')<>''
     and hash<>crypt(coalesce(current_password,''),hash) then
    raise exception 'La contraseña actual no es correcta.';
  end if;
  perform public.write_auth_password(u.email,new_password,false);
  update public.app_users set must_change_password=false where email=u.email;
end $$;
revoke all on function public.change_my_password(text,text) from public, anon;
grant execute on function public.change_my_password(text,text) to authenticated;

-- Quien todavía no tiene contraseña la elige al entrar (por ejemplo, quien ingresó con enlace).
update public.app_users set must_change_password=true where password_set_at is null;

-- El catálogo de centros no se publica en el repositorio. Se importa desde la
-- pantalla Centros una vez autenticado y queda almacenado únicamente en Supabase.

do $$
declare first_admin text := lower('REEMPLAZAR_CON_TU_EMAIL');
begin
  if first_admin='reemplazar_con_tu_email' then
    raise exception 'Reemplazá REEMPLAZAR_CON_TU_EMAIL por tu correo antes de ejecutar';
  end if;
  insert into public.app_users(email,display_name,role,active)
  values(first_admin,'Administrador inicial','administrador',true)
  on conflict(email) do update set role='administrador',active=true;
end $$;
