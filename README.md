# DMO · Asignación de personal

Aplicación web transitoria para mantener y validar la distribución del personal entre centros de costos y centros de beneficios hasta la implementación de Workia.

## Qué resuelve

- Ingreso con correo y contraseña, sin envío de correos.
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
- Supabase Auth: ingreso con correo y contraseña.
- Supabase PostgreSQL: nómina, centros, asignaciones, validaciones e historial.
- Supabase Row Level Security: cada responsable sólo recibe los registros autorizados.

`config.js` contiene una URL y una clave pública de Supabase. Ambas están diseñadas para usarse en el navegador. Nunca agregar al repositorio la `service_role key`, la contraseña de la base ni credenciales SMTP.

## Puesta en marcha

### 1. Crear las tablas y permisos

1. Abrir el proyecto en Supabase.
2. Ir a **SQL Editor** y abrir `supabase/setup.sql`.
3. Reemplazar `REEMPLAZAR_CON_TU_EMAIL` por el correo que usará el primer administrador.
4. Ejecutar el script completo una sola vez.

El script crea las tablas, activa RLS y agrega el primer administrador. El catálogo real de centros no se publica en GitHub: se carga después desde la pantalla autenticada **Centros**.

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

En Supabase, ir a **Authentication > Users > Add user > Create new user**, cargar el mismo correo configurado como administrador en `setup.sql`, una contraseña y marcar **Auto Confirm User**. Con ese correo y contraseña se ingresa a la aplicación, que pide elegir una contraseña propia.

En **Authentication > Sign In / Providers** desactivar **Allow new users to sign up**: las cuentas sólo se crean desde la aplicación.

Desde **Accesos** se crean luego, cada uno con su contraseña inicial:

- usuarios de RRHH;
- responsables con su correo;
- otros administradores, si fueran necesarios.

## Carga inicial y mantenimiento

1. Descargar la plantilla desde la pantalla Nómina.
2. Importar desde **Centros** el Excel vigente de DMO. La hoja debe contener Código, Unidad, Centro y Tipo (Costo o Beneficio).
3. Completar `Responsables`: una fila por responsable y su correo.
4. Completar `Nomina`: legajo, nombre, responsable principal, fecha de alta y fecha de baja opcional.
5. Importar la nómina una sola vez.
6. Después de esa carga, RRHH mantiene altas, bajas y cambios individualmente.

Los centros también se mantienen desde la pantalla **Centros**: **＋ Centro** da de alta uno, **Dar de baja** lo saca de las nuevas asignaciones (los meses anteriores lo conservan) y **Reactivar** lo vuelve a habilitar. Si una persona tenía asignado un centro dado de baja, aparece marcada para reasignar. Volver a importar el catálogo reactiva los centros incluidos en el archivo.

La plantilla incluida contiene personas ficticias para probar. El administrador puede usar **Vaciar datos de prueba** y luego importar los datos reales. Esta acción no borra los centros ni los accesos de RRHH y administración.

## Contraseñas

- Administradores y RRHH asignan la contraseña inicial desde **Accesos** (botón **Asignar** o **Restablecer**). RRHH no puede modificar administradores.
- La contraseña inicial se comunica a la persona por un medio privado. Al ingresar, la aplicación le pide reemplazarla por una propia.
- Si alguien la olvida, se le asigna una nueva desde **Accesos**; su sesión abierta se cierra.
- Cada usuario puede cambiar la suya con el botón **Contraseña** del encabezado.
- Los responsables importados desde el Excel quedan con contraseña **Pendiente** hasta que se les asigne una.

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
