# DMO · Asignación de personal

Aplicación web transitoria para mantener y validar la distribución del personal entre centros de costos y centros de beneficios hasta la implementación de Workia.

## Qué resuelve

- Login sin contraseña mediante enlace enviado por correo.
- Perfiles de RRHH, responsable y administrador de costos.
- Importación inicial desde un Excel con hojas `Nomina` y `Responsables`.
- Altas, bajas y cambios de responsable con fecha.
- Distribución de una persona entre varios centros, obligatoriamente al 100%.
- Confirmación de dedicaciones compartidas por el responsable receptor.
- Click mensual de cada responsable y validación de RRHH.
- Control por excepción y exportación mensual a Excel.
- Historial de actividad.
- Botón para borrar los datos ficticios antes de la carga real.

El navegador no guarda la nómina en `localStorage`. La información queda centralizada en Supabase y los permisos se aplican con Row Level Security.

## Arquitectura

- GitHub Pages: interfaz web estática.
- Supabase Auth: ingreso por correo.
- Supabase PostgreSQL: nómina, centros, asignaciones, validaciones e historial.
- Supabase Row Level Security: cada responsable sólo recibe los registros autorizados.

`config.js` contiene una URL y una clave pública de Supabase. Ambas están diseñadas para usarse en el navegador. Nunca agregar al repositorio la `service_role key`, la contraseña de la base ni credenciales SMTP.

## Puesta en marcha

### 1. Crear las tablas y permisos

1. Abrir el proyecto en Supabase.
2. Ir a **SQL Editor** y abrir `supabase/setup.sql`.
3. Reemplazar `REEMPLAZAR_CON_TU_EMAIL` por el correo que usará el primer administrador.
4. Ejecutar el script completo una sola vez.

El script crea las tablas, carga los 52 centros definidos para DMO, activa RLS y agrega el primer administrador.

### 2. Autorizar la dirección web

En Supabase, ir a **Authentication > URL Configuration** y configurar:

- Site URL: `https://mcruz-creator.github.io/dmo-asignacion-personal/`
- Redirect URL: `https://mcruz-creator.github.io/dmo-asignacion-personal/`

Para probar localmente se puede agregar también `http://localhost:8080/` como Redirect URL.

### 3. Publicar con GitHub Pages

En el repositorio, abrir **Settings > Pages** y seleccionar:

- Source: `Deploy from a branch`
- Branch: `main`
- Folder: `/ (root)`

La aplicación quedará disponible en:

`https://mcruz-creator.github.io/dmo-asignacion-personal/`

### 4. Primer ingreso

Ingresar con el mismo correo configurado como administrador en `setup.sql`. Supabase enviará un enlace de acceso. Desde **Accesos** se crean luego:

- usuarios de RRHH;
- responsables con su correo;
- otros administradores, si fueran necesarios.

## Carga inicial y mantenimiento

1. Descargar la plantilla desde la pantalla Nómina.
2. Completar `Responsables`: una fila por responsable y su correo.
3. Completar `Nomina`: legajo, nombre, responsable principal, fecha de alta y fecha de baja opcional.
4. Importar el archivo una sola vez.
5. Después de esa carga, RRHH mantiene altas, bajas y cambios individualmente.

La plantilla incluida contiene personas ficticias para probar. El administrador puede usar **Vaciar datos de prueba** y luego importar los datos reales. Esta acción no borra los centros ni los accesos de RRHH y administración.

## Correo de acceso

El servicio de correo predeterminado de Supabase sirve para una prueba limitada. Antes de habilitar a todos los responsables debe configurarse un SMTP propio en **Authentication > SMTP Settings**. Puede utilizarse el servicio institucional o un proveedor compatible.

## Seguridad y alcance

- El código del repositorio puede ser público; la nómina no se publica en GitHub.
- Los nombres y legajos siguen siendo datos personales. El acceso debe limitarse a usuarios autorizados.
- Ocultar botones no es un control de seguridad. Las políticas RLS y las funciones de validación vuelven a comprobar permisos y el total de 100% en la base.
- La solución está pensada como herramienta transitoria. La exportación conserva un formato simple para facilitar la futura migración a Workia.

## Prueba local

Desde la carpeta del proyecto:

```bash
python3 -m http.server 8080
```

Luego abrir `http://localhost:8080/`. El login sólo funcionará si esa URL está autorizada en Supabase.
