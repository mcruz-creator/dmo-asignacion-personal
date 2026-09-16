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
drop policy if exists shared_confirmation_write on public.shared_confirmations;
create policy shared_confirmation_write on public.shared_confirmations for all to authenticated
using (exists(select 1 from public.centers c where c.id=center_id and c.responsible_id=public.current_responsible_id()) or public.is_hr_or_admin())
with check (exists(select 1 from public.centers c where c.id=center_id and c.responsible_id=public.current_responsible_id()) or public.is_hr_or_admin());

drop policy if exists monthly_validation_read on public.monthly_validations;
create policy monthly_validation_read on public.monthly_validations for select to authenticated using (public.is_active_user());
drop policy if exists monthly_validation_write on public.monthly_validations;
create policy monthly_validation_write on public.monthly_validations for all to authenticated
using (public.current_role()='administrador')
with check (public.current_role()='administrador');

drop policy if exists hr_validation_read on public.hr_validations;
create policy hr_validation_read on public.hr_validations for select to authenticated using (public.is_active_user());
drop policy if exists hr_validation_write on public.hr_validations;
create policy hr_validation_write on public.hr_validations for all to authenticated using (public.is_hr_or_admin()) with check (public.is_hr_or_admin());

drop policy if exists audit_read on public.audit_events;
create policy audit_read on public.audit_events for select to authenticated using (public.is_hr_or_admin());
drop policy if exists audit_insert on public.audit_events;
create policy audit_insert on public.audit_events for insert to authenticated with check (actor_email=public.current_email() and public.is_active_user());

create or replace function public.save_assignment(
  p_person_id text,
  p_valid_from date,
  p_lines jsonb
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  v_version uuid;
  v_total numeric;
  v_owner uuid;
begin
  select responsible_id into v_owner from public.people where id=p_person_id;
  if v_owner is null then raise exception 'Persona inexistente'; end if;
  if not public.is_hr_or_admin() and v_owner is distinct from public.current_responsible_id() then
    raise exception 'No tiene permiso para asignar esta persona';
  end if;
  select coalesce(sum((x->>'pct')::numeric),0) into v_total from jsonb_array_elements(p_lines) x;
  if abs(v_total-100) > 0.0001 then raise exception 'La asignación debe sumar 100%%'; end if;
  if exists(select 1 from jsonb_array_elements(p_lines) x group by x->>'center_id' having count(*)>1) then
    raise exception 'No se puede repetir un centro';
  end if;
  update public.assignment_versions
    set valid_to=p_valid_from-1
    where person_id=p_person_id and valid_from<p_valid_from and (valid_to is null or valid_to>=p_valid_from);
  delete from public.assignment_versions where person_id=p_person_id and valid_from=p_valid_from;
  insert into public.assignment_versions(person_id,valid_from,created_by)
    values(p_person_id,p_valid_from,public.current_email()) returning id into v_version;
  insert into public.assignment_lines(version_id,center_id,pct)
    select v_version,x->>'center_id',(x->>'pct')::numeric from jsonb_array_elements(p_lines) x;
  delete from public.shared_confirmations where person_id=p_person_id and period>=date_trunc('month',p_valid_from)::date;
  delete from public.monthly_validations where period>=date_trunc('month',p_valid_from)::date;
  delete from public.hr_validations where period>=date_trunc('month',p_valid_from)::date;
  insert into public.audit_events(actor_email,event_type,description)
    values(public.current_email(),'assignment','Asignación actualizada para '||p_person_id||' desde '||p_valid_from);
  return v_version;
end $$;

revoke all on function public.save_assignment(text,date,jsonb) from public;
grant execute on function public.save_assignment(text,date,jsonb) to authenticated;

create or replace function public.validate_responsible_month(p_period date)
returns void language plpgsql security definer set search_path=public
as $$
declare
  v_rid uuid := public.current_responsible_id();
  v_month date := date_trunc('month',p_period)::date;
  v_end date := (date_trunc('month',p_period)+interval '1 month-1 day')::date;
begin
  if public.current_role()<>'responsable' or v_rid is null then
    raise exception 'Sólo un responsable habilitado puede validar su mes';
  end if;
  if exists (
    select 1 from public.people p
    left join lateral (
      select v.id from public.assignment_versions v
      where v.person_id=p.id and v.valid_from<=least(coalesce(p.end_date,v_end),v_end)
        and (v.valid_to is null or v.valid_to>=least(coalesce(p.end_date,v_end),v_end))
      order by v.valid_from desc limit 1
    ) v on true
    left join public.assignment_lines l on l.version_id=v.id
    where p.responsible_id=v_rid and p.start_date<=v_end and (p.end_date is null or p.end_date>=v_month)
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
    join public.assignment_lines l on l.version_id=v.id
    join public.centers c on c.id=l.center_id
    left join public.shared_confirmations sc on sc.period=v_month and sc.person_id=p.id and sc.center_id=c.id and sc.version_id=v.id
    where p.start_date<=v_end and (p.end_date is null or p.end_date>=v_month)
      and ((p.responsible_id=v_rid and c.responsible_id is not null and c.responsible_id<>v_rid)
        or (p.responsible_id<>v_rid and c.responsible_id=v_rid))
      and sc.person_id is null
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
  update public.centers set responsible_id=null where responsible_id is not null;
  delete from public.app_users where role='responsable';
  delete from public.people;
  delete from public.responsibles;
  delete from public.shared_confirmations;
  delete from public.monthly_validations;
  delete from public.hr_validations;
  insert into public.audit_events(actor_email,event_type,description)
  values(public.current_email(),'clear_test','Se vaciaron los datos operativos para realizar la carga real');
end $$;

revoke all on function public.clear_operational_data() from public;
grant execute on function public.clear_operational_data() to authenticated;

create or replace function public.invalidate_people_control()
returns trigger language plpgsql security definer set search_path=public
as $$
declare v_month date := date_trunc('month',current_date)::date;
begin
  delete from public.shared_confirmations where period>=v_month;
  delete from public.monthly_validations where period>=v_month;
  delete from public.hr_validations where period>=v_month;
  return new;
end $$;

drop trigger if exists people_invalidate_control on public.people;
create trigger people_invalidate_control after insert or update of start_date,end_date,responsible_id on public.people
for each statement execute function public.invalidate_people_control();

create or replace function public.invalidate_center_control()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  if old.responsible_id is distinct from new.responsible_id then
    delete from public.shared_confirmations;
    delete from public.monthly_validations;
  end if;
  return new;
end $$;

drop trigger if exists center_invalidate_control on public.centers;
create trigger center_invalidate_control after update of responsible_id on public.centers
for each row execute function public.invalidate_center_control();

grant select,insert,update,delete on public.responsibles,public.app_users,public.centers,public.people,
  public.responsible_history,public.assignment_versions,public.assignment_lines,public.shared_confirmations,
  public.monthly_validations,public.hr_validations,public.audit_events to authenticated;
grant usage,select on sequence public.audit_events_id_seq to authenticated;

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
