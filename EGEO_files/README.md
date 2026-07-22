# Productividad de planta — Supabase + Netlify

Aplicación web (mobile-first) para registrar tareas de producción de piezas inyectadas y consultar el desempeño diario de la operación.

- **Roles acumulativos:** `operario` (registra tareas) → `supervisor` (además crea pedidos y ve tareas) → `admin` (además administra el maestro de artículos).
- **Tablero** de control con datos a día vencido (día anterior).
- Backend gratuito en **Supabase** (Postgres + Auth + RLS), frontend gratuito en **Netlify**.

---

## 1. Crear el proyecto en Supabase

1. Entrá a https://supabase.com y creá un proyecto nuevo (plan Free).
2. Cuando esté listo, abrí **SQL Editor → New query**, pegá el contenido de `supabase/schema.sql` y ejecutá (**Run**).
3. (Opcional) Repetí con `supabase/seed.sql` para cargar artículos de ejemplo.
4. En **Project Settings → API** copiá:
   - **Project URL** → `VITE_SUPABASE_URL`
   - **anon public key** → `VITE_SUPABASE_ANON_KEY`

### Crear el primer administrador
1. Ingresá a la app y usá **Crear una** cuenta (o **Authentication → Users → Add user** en Supabase).
2. Convertí ese usuario en admin desde **SQL Editor**:
   ```sql
   update public.perfiles set rol = 'admin'
   where id = (select id from auth.users where email = 'TU_EMAIL');
   ```
3. Los roles `supervisor` / `operario` se asignan igual, cambiando el valor de `rol`.

> Para uso interno sin confirmación por mail: **Authentication → Providers → Email** y desactivá *Confirm email*. Así las cuentas nuevas ingresan directo.

---

## 2. Correr en local

```bash
npm install
cp .env.example .env      # completá con tu URL y anon key
npm run dev
```

Abre en `http://localhost:5173`.

---

## 3. Publicar en Netlify

1. Subí este proyecto a un repositorio (GitHub/GitLab).
2. En https://netlify.com → **Add new site → Import an existing project** y elegí el repo.
3. Netlify detecta `netlify.toml` (build `npm run build`, publish `dist`).
4. En **Site settings → Environment variables** agregá:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
5. **Deploy**. Cada push actualiza el sitio.

> El plan gratuito de Netlify permite uso comercial. La `anon key` de Supabase es pública por diseño: la seguridad real la imponen las políticas RLS del `schema.sql`.

---

## Estructura

```
supabase/schema.sql   Tablas, vistas, roles y políticas RLS
supabase/seed.sql     Artículos de ejemplo (opcional)
src/api.js            Acceso a datos
src/App.jsx           Interfaz y lógica
src/styles.css        Estilos
```

## Modelo de datos

- **articulos** — maestro con tiempo estándar por unidad de cada actividad (inyectado, rebabado, armado, embolsado) y estado activo/inactivo.
- **pedidos** — código de orden (manual y obligatorio) + artículo + cantidad. El estado se recalcula solo según el avance.
- **tareas** — actividad, inicio, fin, piezas OK y scrap. La duración y la productividad se derivan de estos datos.

## Cómo se calcula la productividad

`productividad = (piezas_ok × tiempo_estándar) ÷ tiempo_real × 100`

El **tiempo estimado** de producción es `piezas_ok × tiempo_estándar`. El objetivo es cumplir el estándar (100%). El tablero agrega estos valores por operario y por día.
