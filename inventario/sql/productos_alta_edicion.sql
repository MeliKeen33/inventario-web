-- ============================================================
--  Alta, edición y baja de productos en una sola operación.
--  Pegar entero en el SQL Editor de Supabase. Se puede volver a
--  correr: reemplaza las funciones si ya existen.
--
--  Por qué funciones: desde el navegador, insertar producto,
--  composición y movimiento son tres pedidos separados. Si falla
--  el segundo, el primero ya quedó guardado. Dentro de una función
--  todo es una transacción: o entra todo o no entra nada.
--
--  SECURITY INVOKER: corren con los permisos de quien las llama,
--  así que las policies de RLS siguen aplicando igual que hoy.
--
--  Supone:
--    productos_terminados(codigo, ...)
--    composicion(producto, producto_terminado, cantidad)
--    motivo STOCK_INICIAL cargado en motivos con signo +1
-- ============================================================


-- Regla: Figura (COR con código F...) y SE necesitan al menos un
-- producto terminado en la composición. Se usa en alta y edición.
create or replace function exige_composicion(p_tipo text, p_codigo text)
returns boolean
language sql immutable
as $$
  select p_tipo = 'SE' or (p_tipo = 'COR' and p_codigo ~ '^F[0-9]');
$$;


-- ---------- ALTA ----------
create or replace function alta_producto(
  p_producto      jsonb,   -- {codigo, descripcion, tipo, origen, posicion, etapa, familia}
  p_composicion   jsonb,   -- [{producto_terminado, cantidad}, ...]
  p_stock_inicial integer, -- null o 0: sin movimiento
  p_fecha         date     -- fecha local de quien carga
)
returns text
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_codigo text := p_producto->>'codigo';
  v_tipo   text := p_producto->>'tipo';
begin
  if exists (select 1 from productos where codigo = v_codigo) then
    raise exception 'Ese código ya existe, el producto ya está dado de alta'
      using errcode = 'unique_violation';
  end if;

  if exige_composicion(v_tipo, v_codigo)
     and jsonb_array_length(coalesce(p_composicion, '[]'::jsonb)) = 0 then
    raise exception 'Figuras y semielaborados necesitan al menos un producto terminado asociado'
      using errcode = 'check_violation';
  end if;

  insert into productos (codigo, descripcion, tipo, origen, posicion, etapa, familia)
  values (
    v_codigo,
    p_producto->>'descripcion',
    v_tipo,
    p_producto->>'origen',
    nullif(p_producto->>'posicion', ''),
    nullif(p_producto->>'etapa', ''),
    case when jsonb_typeof(p_producto->'familia') = 'array'
         then array(select jsonb_array_elements_text(p_producto->'familia'))
    end
  );

  insert into composicion (producto, producto_terminado, cantidad)
  select v_codigo, c->>'producto_terminado', (c->>'cantidad')::integer
  from jsonb_array_elements(coalesce(p_composicion, '[]'::jsonb)) as c;

  if coalesce(p_stock_inicial, 0) > 0 then
    -- usuario lo completa el trigger; el signo, aplicar_signo.
    insert into movimientos (producto, fecha, cantidad, motivo)
    values (v_codigo, p_fecha, p_stock_inicial, 'STOCK_INICIAL');
  end if;

  return v_codigo;
end;
$$;


-- ---------- EDICIÓN ----------
-- El código no se toca. La composición se reemplaza entera por la
-- que manda la ficha, en la misma transacción que los datos.
create or replace function editar_producto(
  p_codigo      text,
  p_cambios     jsonb,  -- {descripcion, origen, posicion, etapa, familia, activo}
  p_composicion jsonb   -- [{producto_terminado, cantidad}, ...]
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_tipo text;
begin
  update productos set
    descripcion = p_cambios->>'descripcion',
    origen      = p_cambios->>'origen',
    posicion    = nullif(p_cambios->>'posicion', ''),
    etapa       = nullif(p_cambios->>'etapa', ''),
    familia     = case when jsonb_typeof(p_cambios->'familia') = 'array'
                       then array(select jsonb_array_elements_text(p_cambios->'familia'))
                  end,
    activo      = (p_cambios->>'activo')::boolean
  where codigo = p_codigo
  returning tipo into v_tipo;

  if not found then
    raise exception 'No se pudo guardar: el producto % no existe o no tenés permiso para editarlo', p_codigo;
  end if;

  if exige_composicion(v_tipo, p_codigo)
     and jsonb_array_length(coalesce(p_composicion, '[]'::jsonb)) = 0 then
    raise exception 'Figuras y semielaborados necesitan al menos un producto terminado asociado'
      using errcode = 'check_violation';
  end if;

  delete from composicion where producto = p_codigo;

  insert into composicion (producto, producto_terminado, cantidad)
  select p_codigo, c->>'producto_terminado', (c->>'cantidad')::integer
  from jsonb_array_elements(coalesce(p_composicion, '[]'::jsonb)) as c;
end;
$$;


-- ---------- BAJA ----------
-- Borra composición y producto juntos. Si la policy de productos no
-- deja borrarlo (tiene movimientos), no se borra nada.
create or replace function eliminar_producto(p_codigo text)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  delete from composicion where producto = p_codigo;
  delete from productos where codigo = p_codigo;

  if not found then
    raise exception 'TIENE_MOVIMIENTOS'
      using hint = 'La policy no dejó borrar el producto: tiene movimientos registrados o no tenés permiso.';
  end if;
end;
$$;


-- Solo usuarios con sesión. RLS decide qué puede hacer cada rol.
revoke execute on function alta_producto(jsonb, jsonb, integer, date) from public, anon;
revoke execute on function editar_producto(text, jsonb, jsonb)       from public, anon;
revoke execute on function eliminar_producto(text)                   from public, anon;
grant execute on function alta_producto(jsonb, jsonb, integer, date) to authenticated;
grant execute on function editar_producto(text, jsonb, jsonb)       to authenticated;
grant execute on function eliminar_producto(text)                   to authenticated;
