-- ═══════════════════════════════════════════════════════════════
--  طلبات الاسترجاع / الاستبدال + صورة الفاتورة
--  شغّله مرة واحدة من Supabase → SQL Editor (اختار Run without RLS)
--  ويتشغّل أكتر من مرة من غير مشاكل.
--
--  • الأوردر الأصلي لازم يكون حالته "خرج للشحن" (shipped).
--  • الأوردر الجديد بيتعمل بنفس بيانات العميل (اسم/عنوان/موبايلات/محافظة/منطقة)
--    + المنتج المطلوب + سعر الشحن، وبيتحفظ "مؤكد" على طول.
--  • صورة الفاتورة شرط، ومتخزنة في جدول لوحدها (order_invoices)
--    عشان ما تتقّلش تحميل صفحة الأوردرات.
--  • أوردر الاسترجاع/الاستبدال مش بيتحسب "مكرر" مع الأوردر الأصلي.
-- ═══════════════════════════════════════════════════════════════
begin;

-- 1) أعمدة جديدة في الأوردرات
alter table public.orders add column if not exists return_type     text;   -- return | exchange
alter table public.orders add column if not exists parent_order_id text references public.orders(id) on delete set null;
alter table public.orders drop constraint if exists orders_return_type_chk;
alter table public.orders add  constraint orders_return_type_chk check (return_type is null or return_type in ('return','exchange'));
create index if not exists orders_parent_idx on public.orders (parent_order_id) where parent_order_id is not null;

-- 2) صور الفواتير
create table if not exists public.order_invoices (
  order_id    text primary key references public.orders(id) on delete cascade,
  image       text not null,              -- data:image/jpeg;base64,...
  uploaded_by text,
  uploader    text,
  created_at  timestamptz not null default now()
);
alter table public.order_invoices enable row level security;
revoke all on public.order_invoices from anon, authenticated;
grant select on public.order_invoices to anon, authenticated;     -- الإضافة من خلال الدالة تحت بس
drop policy if exists invoices_select on public.order_invoices;
-- اللي يقدر يشوف الأوردر يقدر يشوف فاتورته
create policy invoices_select on public.order_invoices for select
  using (exists (select 1 from public.orders o where o.id = order_invoices.order_id));

-- 3) البحث برقم الموبايل عن أوردرات "خرج للشحن" (أدمن + كول سنتر، على كل الأوردرات)
drop function if exists public.app_return_candidates(text);
create or replace function public.app_return_candidates(p_phone text)
returns table(id text, order_ref text, customer_name text, customer_phone text, customer_alt_phone text,
              city text, area text, customer_address text, product_name text, quantity int,
              total_cost numeric, status_updated_at timestamptz, created_at timestamptz, existing_ref text)
language sql stable security definer set search_path = public, extensions as $$
  with q as (
    select right(regexp_replace(translate(coalesce(p_phone, ''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '\D', '', 'g'), 10) as ph
  )
  select o.id, o.order_ref, o.customer_name, o.customer_phone, o.customer_alt_phone,
         o.city, o.area, o.customer_address, o.product_name, o.quantity,
         o.total_cost, o.status_updated_at, o.created_at,
         (select c.order_ref from public.orders c
           where c.parent_order_id = o.id and c.status <> 'cancelled'
           order by c.created_at desc limit 1)
    from public.orders o, q
   where public.app_role() in ('admin', 'call_center')
     and length(q.ph) >= 8
     and o.status = 'shipped'
     and (   right(regexp_replace(translate(coalesce(o.customer_phone, ''),     '٠١٢٣٤٥٦٧٨٩', '0123456789'), '\D', '', 'g'), 10) = q.ph
          or right(regexp_replace(translate(coalesce(o.customer_alt_phone, ''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '\D', '', 'g'), 10) = q.ph)
   order by o.status_updated_at desc nulls last
   limit 50
$$;

-- 4) إنشاء أوردر الاسترجاع/الاستبدال (كله في خطوة واحدة على السيرفر)
drop function if exists public.app_create_return(text, text, text, numeric, text, text);
create or replace function public.app_create_return(
  p_parent text, p_type text, p_product text, p_shipping numeric, p_invoice text, p_note text default null)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  me    text := public.app_uid();
  rl    text := public.app_role();
  par   public.orders;
  nid   text := gen_random_uuid()::text;
  base  text;
  ref   text;
  n     int  := 1;
  lbl   text;
begin
  if me is null or rl not in ('admin', 'call_center') then raise exception 'not_allowed'; end if;
  if p_type not in ('return', 'exchange') then raise exception 'bad_type'; end if;
  if coalesce(btrim(p_product), '') = '' then raise exception 'product_required'; end if;
  if p_shipping is null or p_shipping < 0 then raise exception 'bad_shipping'; end if;
  if p_invoice is null or p_invoice !~ '^data:image/(jpeg|png|webp);base64,' then raise exception 'invoice_required'; end if;
  if length(p_invoice) > 4000000 then raise exception 'invoice_too_big'; end if;

  perform pg_advisory_xact_lock(hashtext('return:' || p_parent));
  par := (select o from public.orders o where o.id = p_parent);
  if par.id is null then raise exception 'order_not_found'; end if;
  if par.status <> 'shipped' then raise exception 'not_shipped'; end if;
  if exists (select 1 from public.orders c where c.parent_order_id = par.id and c.status <> 'cancelled') then
    raise exception 'already_exists';
  end if;

  lbl  := case p_type when 'return' then 'استرجاع' else 'استبدال' end;
  base := par.order_ref || case p_type when 'return' then '-R' else '-EX' end;
  ref  := base;
  while exists (select 1 from public.orders x where x.order_ref = ref) loop
    n := n + 1; ref := base || n;
  end loop;

  insert into public.orders (
    id, order_ref, customer_name, customer_phone, customer_alt_phone, city, area, customer_address,
    product_name, quantity, item_price, product_cost, total_cost, shipping_cost, discount,
    payment_method, note, status, assigned_to, affiliate_id, return_type, parent_order_id,
    created_at, updated_at, status_updated_at)
  values (
    nid, ref, par.customer_name, par.customer_phone, par.customer_alt_phone, par.city, par.area, par.customer_address,
    btrim(p_product), 1, 0, 0, p_shipping, p_shipping, 0,
    'cod',
    lbl || ' — أوردر أصلي #' || par.order_ref || coalesce(' — ' || nullif(btrim(p_note), ''), ''),
    'confirmed',
    case when rl = 'call_center' then me else par.assigned_to end,
    null, p_type, par.id,
    now(), now(), now());

  insert into public.order_invoices (order_id, image, uploaded_by, uploader)
  values (nid, p_invoice, me, (select name from public.users where id = me));

  insert into public.audit_logs (id, user_id, user_name, action, entity, detail, created_at)
  values (gen_random_uuid()::text, me, (select name from public.users where id = me),
          'طلب ' || lbl, 'order', lbl || ' ' || ref || ' للأوردر ' || par.order_ref, now());

  return json_build_object('id', nid, 'order_ref', ref);
end $$;

grant execute on function public.app_return_candidates(text) to anon, authenticated;
grant execute on function public.app_create_return(text, text, text, numeric, text, text) to anon, authenticated;

-- 5) المكرر: أوردرات الاسترجاع/الاستبدال مش بتتحسب مكررة (نفس العميل طبيعي)
create or replace function public.app_duplicates()
returns table(
  order_id text, other_id text, other_ref text, other_created timestamptz, other_status text,
  match_name boolean, match_phone boolean, match_address boolean, is_earlier boolean)
language sql stable security definer set search_path = public, extensions as $$
  with n as (
    select o.id, o.order_ref, o.created_at, o.status, o.assigned_to,
           nullif(lower(btrim(regexp_replace(coalesce(o.customer_name, ''), '\s+', ' ', 'g'))), '') as nm,
           case when length(d.digits) >= 8 then right(d.digits, 10) end as ph,
           nullif(lower(btrim(regexp_replace(coalesce(o.customer_address, ''), '\s+', ' ', 'g'))), '') as ad
      from orders o
      cross join lateral (
        select regexp_replace(translate(coalesce(o.customer_phone, ''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '\D', '', 'g') as digits
      ) d
     where o.parent_order_id is null
  ),
  pairs as (
    select a.id as aid, b.id as bid from n a join n b on a.nm = b.nm and a.id <> b.id
    union
    select a.id, b.id from n a join n b on a.ph = b.ph and a.id <> b.id
    union
    select a.id, b.id from n a join n b on a.ad = b.ad and a.id <> b.id
  )
  select a.id, b.id, b.order_ref, b.created_at, b.status,
         coalesce(a.nm = b.nm, false), coalesce(a.ph = b.ph, false), coalesce(a.ad = b.ad, false),
         (b.created_at < a.created_at or (b.created_at = a.created_at and b.id < a.id))
    from pairs p
    join n a on a.id = p.aid
    join n b on b.id = p.bid
   where public.app_uid() is not null
     and (   public.app_role() = 'admin'
          or (public.app_role() = 'call_center' and a.assigned_to = public.app_uid())
          or (public.app_role() = 'shipping' and a.status in ('confirmed','shipped','delivered','not_delivered')))
   order by a.id, b.id
$$;

commit;
