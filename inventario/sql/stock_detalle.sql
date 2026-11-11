-- ============================================================
--  Vista stock_detalle: el stock de cada producto con su tipo y
--  su etapa, para filtrar y mostrar en la pestaña Stock.
--  Pegar entero en el SQL Editor de Supabase. Se puede volver a
--  correr.
--
--  Por qué una vista nueva y no cambiar stock: no toca la
--  definición de stock (que sigue siendo la única fuente del
--  saldo, calculado desde movimientos) y solo usa columnas que
--  stock ya tiene. No guarda ningún número: es otra vista.
--
--  security_invoker: se lee con los permisos de quien consulta,
--  así que las policies de RLS de productos siguen aplicando.
-- ============================================================

create or replace view stock_detalle
with (security_invoker = true)
as
select s.codigo,
       s.descripcion,
       s.stock,
       s.posicion,
       p.tipo,
       p.etapa
from stock s
join productos p on p.codigo = s.codigo;

revoke all on stock_detalle from anon;
grant select on stock_detalle to authenticated;
