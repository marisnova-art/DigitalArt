-- =====================================================================
-- MarisNova Digital Art Platform — Supabase schema (migration 001)
-- Supabase Dashboard → SQL Editor 에서 새 프로젝트에 1회 실행하세요.
-- 포함: 테이블, 제약, 인덱스, 트리거, 검색 RPC, RLS, Storage 버킷/정책
-- =====================================================================

create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------
-- 0. 공통 함수
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 1. 권한(역할) — 사용자가 직접 수정할 수 없는 별도 테이블
--    INSERT/UPDATE/DELETE 정책이 없으므로 SQL Editor(서버)에서만 부여 가능
-- ---------------------------------------------------------------------
create table if not exists public.user_roles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       text not null default 'admin' check (role in ('admin')),
  created_at timestamptz not null default now()
);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_roles
    where user_id = auth.uid() and role = 'admin'
  );
$$;
grant execute on function public.is_admin() to anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. profiles — 최소 수집(표시 이름, 아바타, 선호 언어)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text check (char_length(display_name) <= 60),
  avatar_url   text,
  locale       text check (locale in ('ko','en')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_avatar text := new.raw_user_meta_data->>'avatar_url';
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    left(coalesce(new.raw_user_meta_data->>'display_name',
                  new.raw_user_meta_data->>'full_name',
                  new.raw_user_meta_data->>'name',
                  split_part(new.email, '@', 1)), 60),
    case when v_avatar ~* '^https://' then v_avatar end
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- 3. categories / tags
-- ---------------------------------------------------------------------
create table if not exists public.categories (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (char_length(name) between 1 and 80),
  name_en        text check (char_length(name_en) <= 80),
  slug           text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  description    text,
  description_en text,
  cover_url      text check (cover_url is null or cover_url ~* '^https://'),
  sort_order     int  not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create trigger categories_updated before update on public.categories
  for each row execute function public.set_updated_at();

create table if not exists public.tags (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 60),
  -- 한글 태그 허용: 공백·/ ? # % 만 금지
  slug       text not null unique check (char_length(slug) between 1 and 60 and slug !~ '[[:space:]/?#%]'),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4. brands — 작품별 독립 브랜드 페이지
-- ---------------------------------------------------------------------
create table if not exists public.brands (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null check (char_length(name) between 1 and 120),
  name_en               text,
  slug                  text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  tagline               text,
  tagline_en            text,
  description           text,
  description_en        text,
  logo_url              text,
  cover_url             text,               -- 이미지 또는 .mp4/.webm 영상
  featured_artwork_id   uuid,               -- FK는 artworks 생성 후 추가
  donation_url          text,
  donation_label        text,               -- 예: Ko-fi, Buy Me a Coffee
  gumroad_url           text,
  gumroad_price         text,
  gumroad_note          text,
  redbubble_url         text,
  redbubble_preview_url text,
  social_links          jsonb not null default '{}'::jsonb check (jsonb_typeof(social_links) = 'object'),
  license_text          text,
  license_text_en       text,
  seo_title             text,
  seo_title_en          text,
  seo_description       text,
  seo_description_en    text,
  og_image_url          text,
  is_published          boolean not null default false,
  is_featured           boolean not null default false,
  sort_order            int not null default 0,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz,
  constraint brands_slug_key unique (slug),
  constraint brands_https_urls check (
        (logo_url              is null or logo_url              ~* '^https://')
    and (cover_url             is null or cover_url             ~* '^https://')
    and (donation_url          is null or donation_url          ~* '^https://')
    and (gumroad_url           is null or gumroad_url           ~* '^https://')
    and (redbubble_url         is null or redbubble_url         ~* '^https://')
    and (redbubble_preview_url is null or redbubble_preview_url ~* '^https://')
    and (og_image_url          is null or og_image_url          ~* '^https://')
  )
);

-- ---------------------------------------------------------------------
-- 5. artworks
-- ---------------------------------------------------------------------
create table if not exists public.artworks (
  id              uuid primary key default gen_random_uuid(),
  title           text not null check (char_length(title) between 1 and 200),
  title_en        text,
  slug            text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  summary         text,           -- 간단한 소개
  summary_en      text,
  description     text,           -- 상세 설명
  description_en  text,
  thumbnail_url   text,           -- 공개 썸네일 (public-media 버킷)
  preview_url     text,           -- 공개 미리보기 이미지/영상
  original_path   text,           -- 비공개 원본 경로 (originals 버킷)
  media_type      text not null default 'image' check (media_type in ('image','video')),
  width           int  check (width  is null or width  between 1 and 20000),
  height          int  check (height is null or height between 1 and 20000),
  category_id     uuid,
  brand_id        uuid,
  created_on      date,           -- 작품 제작일
  is_published    boolean not null default false,
  is_featured     boolean not null default false,
  sort_order      int not null default 0,
  gumroad_url     text,
  redbubble_url   text,
  price_note      text,
  seo_title       text,
  seo_description text,
  og_image_url    text,
  search_text     text,           -- 트리거가 자동 생성 (제목·설명·브랜드·카테고리·태그)
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,    -- 소프트 삭제
  constraint artworks_slug_key unique (slug),
  constraint artworks_brand_id_fkey    foreign key (brand_id)    references public.brands(id)     on delete set null,
  constraint artworks_category_id_fkey foreign key (category_id) references public.categories(id) on delete set null,
  constraint artworks_https_urls check (
        (thumbnail_url is null or thumbnail_url ~* '^https://')
    and (preview_url   is null or preview_url   ~* '^https://')
    and (gumroad_url   is null or gumroad_url   ~* '^https://')
    and (redbubble_url is null or redbubble_url ~* '^https://')
    and (og_image_url  is null or og_image_url  ~* '^https://')
  )
);

alter table public.brands
  add constraint brands_featured_artwork_id_fkey
  foreign key (featured_artwork_id) references public.artworks(id) on delete set null;

create table if not exists public.artwork_tags (
  artwork_id uuid not null references public.artworks(id) on delete cascade,
  tag_id     uuid not null references public.tags(id)     on delete cascade,
  primary key (artwork_id, tag_id)
);

-- 집계 카운터는 별도 테이블 (작품 updated_at 오염 방지, 클라이언트 수정 불가)
create table if not exists public.artwork_stats (
  artwork_id      uuid primary key references public.artworks(id) on delete cascade,
  favorites_count int    not null default 0,
  view_count      bigint not null default 0
);

-- ---------------------------------------------------------------------
-- 6. banners / favorites / site_settings / deletion_requests
-- ---------------------------------------------------------------------
create table if not exists public.banners (
  id               uuid primary key default gen_random_uuid(),
  title            text not null check (char_length(title) between 1 and 160),
  title_en         text,
  subtitle         text,
  subtitle_en      text,
  image_url        text,
  mobile_image_url text,
  video_url        text,
  target_brand_id  uuid references public.brands(id) on delete set null,
  target_url       text,
  button_text      text,
  button_text_en   text,
  is_active        boolean not null default true,
  start_at         timestamptz,
  end_at           timestamptz,
  sort_order       int not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint banners_period check (start_at is null or end_at is null or end_at > start_at),
  constraint banners_https_urls check (
        (image_url        is null or image_url        ~* '^https://')
    and (mobile_image_url is null or mobile_image_url ~* '^https://')
    and (video_url        is null or video_url        ~* '^https://')
    and (target_url       is null or target_url       ~* '^https://')
  )
);
create trigger banners_updated before update on public.banners
  for each row execute function public.set_updated_at();

create table if not exists public.favorites (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  artwork_id uuid not null references public.artworks(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint favorites_user_artwork_key unique (user_id, artwork_id)
);

create table if not exists public.site_settings (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create trigger site_settings_updated before update on public.site_settings
  for each row execute function public.set_updated_at();

create table if not exists public.deletion_requests (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  email      text,
  reason     text check (char_length(reason) <= 1000),
  status     text not null default 'pending' check (status in ('pending','done','rejected')),
  created_at timestamptz not null default now(),
  handled_at timestamptz
);
create unique index if not exists deletion_requests_one_pending
  on public.deletion_requests (user_id) where status = 'pending';

-- ---------------------------------------------------------------------
-- 7. 인덱스
-- ---------------------------------------------------------------------
create index if not exists artworks_pub_created_idx on public.artworks (created_at desc)
  where is_published and deleted_at is null;
create index if not exists artworks_pub_sort_idx on public.artworks (sort_order, created_at desc)
  where is_published and deleted_at is null;
create index if not exists artworks_brand_idx    on public.artworks (brand_id);
create index if not exists artworks_category_idx on public.artworks (category_id);
create index if not exists artworks_featured_idx on public.artworks (is_featured) where is_featured;
create index if not exists artworks_updated_idx  on public.artworks (updated_at desc);
create index if not exists artworks_search_trgm  on public.artworks using gin (search_text extensions.gin_trgm_ops);
create index if not exists artwork_tags_tag_idx  on public.artwork_tags (tag_id);
create index if not exists artwork_stats_pop_idx on public.artwork_stats (favorites_count desc, view_count desc);
create index if not exists brands_pub_idx        on public.brands (sort_order, name) where is_published and deleted_at is null;
create index if not exists favorites_user_idx    on public.favorites (user_id, created_at desc);
create index if not exists favorites_artwork_idx on public.favorites (artwork_id);
create index if not exists banners_sort_idx      on public.banners (sort_order);

-- ---------------------------------------------------------------------
-- 8. 트리거 — 검색 텍스트, updated_at, 통계
-- ---------------------------------------------------------------------
create or replace function public.tg_artworks_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.search_text := lower(concat_ws(' ',
    new.title, new.title_en, new.slug, new.summary, new.summary_en, new.description, new.description_en,
    (select concat_ws(' ', b.name, b.name_en, b.slug) from public.brands b where b.id = new.brand_id),
    (select concat_ws(' ', c.name, c.name_en, c.slug) from public.categories c where c.id = new.category_id),
    (select string_agg(t.name || ' ' || t.slug, ' ')
       from public.artwork_tags x join public.tags t on t.id = x.tag_id
      where x.artwork_id = new.id)
  ));
  if tg_op = 'UPDATE' and coalesce(current_setting('app.skip_touch', true), '') <> 'on' then
    new.updated_at := now();
  end if;
  return new;
end $$;
drop trigger if exists artworks_before on public.artworks;
create trigger artworks_before before insert or update on public.artworks
  for each row execute function public.tg_artworks_before();

create or replace function public.tg_artworks_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.artwork_stats (artwork_id) values (new.id) on conflict do nothing;
  return null;
end $$;
create trigger artworks_after_insert after insert on public.artworks
  for each row execute function public.tg_artworks_after_insert();

-- 태그 연결 변경 → 해당 작품 검색 텍스트 갱신 (updated_at도 갱신: 실제 편집이므로)
create or replace function public.tg_artwork_tags_touch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    update public.artworks set search_text = search_text where id = old.artwork_id;
  else
    update public.artworks set search_text = search_text where id = new.artwork_id;
  end if;
  return null;
end $$;
create trigger artwork_tags_touch after insert or delete on public.artwork_tags
  for each row execute function public.tg_artwork_tags_touch();

-- 브랜드/카테고리/태그 이름 변경 → 관련 작품 검색 텍스트 갱신 (updated_at은 유지)
create or replace function public.tg_brand_rename() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.name, new.name_en, new.slug) is distinct from (old.name, old.name_en, old.slug) then
    perform set_config('app.skip_touch', 'on', true);
    update public.artworks set search_text = search_text where brand_id = new.id;
    perform set_config('app.skip_touch', '', true);
  end if;
  return null;
end $$;
create trigger brands_rename after update on public.brands
  for each row execute function public.tg_brand_rename();

create or replace function public.tg_category_rename() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.name, new.name_en, new.slug) is distinct from (old.name, old.name_en, old.slug) then
    perform set_config('app.skip_touch', 'on', true);
    update public.artworks set search_text = search_text where category_id = new.id;
    perform set_config('app.skip_touch', '', true);
  end if;
  return null;
end $$;
create trigger categories_rename after update on public.categories
  for each row execute function public.tg_category_rename();

create or replace function public.tg_tag_rename() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.name, new.slug) is distinct from (old.name, old.slug) then
    perform set_config('app.skip_touch', 'on', true);
    update public.artworks a set search_text = a.search_text
      from public.artwork_tags x where x.artwork_id = a.id and x.tag_id = new.id;
    perform set_config('app.skip_touch', '', true);
  end if;
  return null;
end $$;
create trigger tags_rename after update on public.tags
  for each row execute function public.tg_tag_rename();

create trigger brands_updated before update on public.brands
  for each row execute function public.set_updated_at();

-- 즐겨찾기 카운트
create or replace function public.tg_favorites_count() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.artwork_stats (artwork_id, favorites_count) values (new.artwork_id, 1)
    on conflict (artwork_id) do update set favorites_count = public.artwork_stats.favorites_count + 1;
  else
    update public.artwork_stats set favorites_count = greatest(favorites_count - 1, 0)
     where artwork_id = old.artwork_id;
  end if;
  return null;
end $$;
create trigger favorites_count after insert or delete on public.favorites
  for each row execute function public.tg_favorites_count();

-- ---------------------------------------------------------------------
-- 9. RPC — 검색/목록 (서버 측 페이지네이션), 조회수 기록
-- ---------------------------------------------------------------------
create or replace function public.search_artworks(
  p_q        text    default null,
  p_category text    default null,
  p_tag      text    default null,
  p_brand    text    default null,
  p_sort     text    default 'latest',   -- latest | popular | name
  p_featured boolean default null,
  p_lang     text    default 'en',
  p_limit    int     default 30,
  p_offset   int     default 0
)
returns table (
  id uuid, title text, title_en text, slug text, summary text, summary_en text,
  thumbnail_url text, preview_url text, media_type text, width int, height int,
  created_at timestamptz,
  brand_slug text, brand_name text, brand_name_en text,
  category_slug text, category_name text, category_name_en text,
  favorites_count int, view_count bigint, total_count bigint
)
language sql stable security invoker set search_path = public as $$
  with q as (
    select array_remove(regexp_split_to_array(lower(trim(coalesce(p_q, ''))), '\s+'), '') as terms
  )
  select a.id, a.title, a.title_en, a.slug, a.summary, a.summary_en,
         a.thumbnail_url, a.preview_url, a.media_type, a.width, a.height, a.created_at,
         b.slug, b.name, b.name_en, c.slug, c.name, c.name_en,
         coalesce(s.favorites_count, 0), coalesce(s.view_count, 0),
         count(*) over () as total_count
    from public.artworks a
    left join public.brands b        on b.id = a.brand_id
    left join public.categories c    on c.id = a.category_id
    left join public.artwork_stats s on s.artwork_id = a.id
    cross join q
   where a.is_published and a.deleted_at is null
     and (a.brand_id is null or (b.id is not null and b.is_published and b.deleted_at is null))
     and (p_category is null or c.slug = p_category)
     and (p_brand    is null or b.slug = p_brand)
     and (p_featured is null or a.is_featured = p_featured)
     and (p_tag is null or exists (
           select 1 from public.artwork_tags x join public.tags t on t.id = x.tag_id
            where x.artwork_id = a.id and t.slug = p_tag))
     and (cardinality(q.terms) = 0 or (
           select bool_and(a.search_text like '%' || replace(replace(replace(term, '\', '\\'), '%', '\%'), '_', '\_') || '%')
             from unnest(q.terms) as term))
   order by
     case when p_sort = 'popular' then coalesce(s.favorites_count, 0) end desc nulls last,
     case when p_sort = 'popular' then coalesce(s.view_count, 0) end desc nulls last,
     case when p_sort = 'name' then lower(case when p_lang = 'en' then coalesce(nullif(a.title_en, ''), a.title) else a.title end) end asc,
     case when p_sort = 'latest' then a.created_at end desc,
     a.sort_order asc, a.created_at desc, a.id
   limit least(greatest(coalesce(p_limit, 30), 1), 60)
  offset greatest(coalesce(p_offset, 0), 0);
$$;
grant execute on function public.search_artworks(text,text,text,text,text,boolean,text,int,int) to anon, authenticated;

create or replace function public.record_view(p_artwork uuid) returns void
language sql security definer set search_path = public as $$
  insert into public.artwork_stats (artwork_id, view_count)
  select id, 1 from public.artworks where id = p_artwork and is_published and deleted_at is null
  on conflict (artwork_id) do update set view_count = public.artwork_stats.view_count + 1;
$$;
grant execute on function public.record_view(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 10. RLS
-- ---------------------------------------------------------------------
alter table public.user_roles        enable row level security;
alter table public.profiles          enable row level security;
alter table public.categories        enable row level security;
alter table public.tags              enable row level security;
alter table public.brands            enable row level security;
alter table public.artworks          enable row level security;
alter table public.artwork_tags      enable row level security;
alter table public.artwork_stats     enable row level security;
alter table public.banners           enable row level security;
alter table public.favorites         enable row level security;
alter table public.site_settings     enable row level security;
alter table public.deletion_requests enable row level security;

-- user_roles: 본인 역할만 조회. 쓰기 정책 없음 → 클라이언트에서 권한 상승 불가
create policy user_roles_self_read on public.user_roles
  for select to authenticated using (user_id = auth.uid());

-- profiles: 본인만
create policy profiles_self_read   on public.profiles for select to authenticated using (id = auth.uid());
create policy profiles_self_insert on public.profiles for insert to authenticated with check (id = auth.uid());
create policy profiles_self_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- categories / tags / site_settings / artwork_stats: 공개 읽기, 관리자 쓰기
create policy categories_read  on public.categories for select using (true);
create policy categories_admin on public.categories for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

create policy tags_read  on public.tags for select using (true);
create policy tags_admin on public.tags for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

create policy site_settings_read  on public.site_settings for select using (true);
create policy site_settings_admin on public.site_settings for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

create policy artwork_stats_read on public.artwork_stats for select using (true);
-- (쓰기는 security definer 트리거/RPC만)

-- brands: 공개+미삭제만 공개, 관리자는 전체
create policy brands_read on public.brands for select
  using ((is_published and deleted_at is null) or (select public.is_admin()));
create policy brands_admin_insert on public.brands for insert to authenticated with check ((select public.is_admin()));
create policy brands_admin_update on public.brands for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy brands_admin_delete on public.brands for delete to authenticated using ((select public.is_admin()));

-- artworks
create policy artworks_read on public.artworks for select
  using ((is_published and deleted_at is null) or (select public.is_admin()));
create policy artworks_admin_insert on public.artworks for insert to authenticated with check ((select public.is_admin()));
create policy artworks_admin_update on public.artworks for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy artworks_admin_delete on public.artworks for delete to authenticated using ((select public.is_admin()));

-- artwork_tags: 볼 수 있는 작품의 태그 연결만
create policy artwork_tags_read on public.artwork_tags for select
  using (exists (select 1 from public.artworks a where a.id = artwork_id));
create policy artwork_tags_admin on public.artwork_tags for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- banners: 활성 + 노출 기간 내만 공개
create policy banners_read on public.banners for select
  using ((is_active and (start_at is null or start_at <= now()) and (end_at is null or end_at > now()))
         or (select public.is_admin()));
create policy banners_admin on public.banners for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- favorites: 본인 것만, 공개 작품에만 추가 가능
create policy favorites_self_read on public.favorites for select to authenticated using (user_id = auth.uid());
create policy favorites_self_insert on public.favorites for insert to authenticated
  with check (user_id = auth.uid()
              and exists (select 1 from public.artworks a
                           where a.id = artwork_id and a.is_published and a.deleted_at is null));
create policy favorites_self_delete on public.favorites for delete to authenticated using (user_id = auth.uid());

-- deletion_requests: 본인 요청 생성/조회, 관리자 조회/처리
create policy deletion_self_read on public.deletion_requests for select to authenticated
  using (user_id = auth.uid() or (select public.is_admin()));
create policy deletion_self_insert on public.deletion_requests for insert to authenticated
  with check (user_id = auth.uid() and status = 'pending');
create policy deletion_admin_update on public.deletion_requests for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- ---------------------------------------------------------------------
-- 11. Storage — 공개 썸네일 버킷 / 비공개 원본 버킷
--   public-media : 공개 URL 읽기(CDN), 목록 조회·쓰기는 관리자만
--   originals    : 비공개. 관리자만 읽기/쓰기 (서명 URL로 다운로드)
--   ※ file_size_limit은 플랜의 전역 업로드 한도를 넘을 수 없습니다(Free: 50MB).
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('public-media', 'public-media', true, 52428800,
   array['image/jpeg','image/png','image/webp','image/avif','image/gif','video/mp4','video/webm']),
  ('originals', 'originals', false, 524288000, null)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "mn public-media admin select" on storage.objects;
drop policy if exists "mn public-media admin insert" on storage.objects;
drop policy if exists "mn public-media admin update" on storage.objects;
drop policy if exists "mn public-media admin delete" on storage.objects;
drop policy if exists "mn originals admin all"       on storage.objects;

-- 공개 버킷 파일은 public URL로 누구나 읽을 수 있음. 목록(list) API는 관리자만.
create policy "mn public-media admin select" on storage.objects for select to authenticated
  using (bucket_id = 'public-media' and (select public.is_admin()));
create policy "mn public-media admin insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'public-media' and (select public.is_admin()));
create policy "mn public-media admin update" on storage.objects for update to authenticated
  using (bucket_id = 'public-media' and (select public.is_admin()))
  with check (bucket_id = 'public-media' and (select public.is_admin()));
create policy "mn public-media admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'public-media' and (select public.is_admin()));

create policy "mn originals admin all" on storage.objects for all to authenticated
  using (bucket_id = 'originals' and (select public.is_admin()))
  with check (bucket_id = 'originals' and (select public.is_admin()));

-- ---------------------------------------------------------------------
-- 12. 기본 사이트 설정 행
-- ---------------------------------------------------------------------
insert into public.site_settings (key, value) values ('site', '{}'::jsonb)
on conflict (key) do nothing;

-- =====================================================================
-- 관리자 지정 (가입 후 1회, SQL Editor에서):
--   insert into public.user_roles (user_id, role)
--   select id, 'admin' from auth.users where email = 'you@example.com'
--   on conflict (user_id) do nothing;
-- =====================================================================
