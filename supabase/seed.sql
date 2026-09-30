-- =====================================================================
-- MarisNova — 초기 데모 데이터 (선택). schema.sql 실행 후 실행하세요.
-- 이미지가 없는 작품은 앱이 슬러그 기반 생성 아트 플레이스홀더로 표시합니다.
-- 외부 링크(후원·Gumroad·Redbubble)는 비워 두었습니다 — 실제 URL을 관리자에서 입력하세요.
-- =====================================================================

insert into public.categories (name, name_en, slug, sort_order) values
  ('제너러티브',   'Generative',    'generative',    10),
  ('WebGL 엔진',   'WebGL Engines', 'webgl-engine',  20),
  ('오디오 비주얼', 'Audio Visual',  'audio-visual',  30),
  ('포스터',       'Posters',       'poster',        40),
  ('글리치',       'Glitch',        'glitch',        50),
  ('추상',         'Abstract',      'abstract',      60)
on conflict (slug) do nothing;

insert into public.tags (name, slug) values
  ('webgl','webgl'), ('shader','shader'), ('particles','particles'), ('tunnel','tunnel'),
  ('kaleidoscope','kaleidoscope'), ('neon','neon'), ('monochrome','monochrome'),
  ('interactive','interactive'), ('loop','loop'), ('fractal','fractal'), ('네온','네온')
on conflict (slug) do nothing;

insert into public.brands (name, name_en, slug, tagline, tagline_en, description, description_en,
                           is_published, is_featured, sort_order, social_links)
values
  ('터미널', 'Terminal', 'terminal',
   '코드와 빛이 교차하는 단말기 미학', 'Terminal aesthetics where code meets light',
   E'터미널은 텍스트 모드와 스캔라인에서 출발한 실시간 아트 시리즈입니다.',
   E'Terminal is a real-time art series born from text modes and scanlines.',
   true, true, 10, '{}'::jsonb),
  ('하이프보이', 'Hypeboy', 'hypeboy',
   '리듬에 반응하는 네온 모션 시리즈', 'Neon motion series that reacts to rhythm',
   E'오디오 입력에 반응하는 네온 모션 그래픽 모음입니다.',
   E'A collection of neon motion graphics that respond to audio.',
   true, true, 20, '{}'::jsonb),
  ('그레이스풀 웨이브', 'Graceful Wave', 'graceful-wave',
   '느리게 호흡하는 파동과 색면', 'Slow-breathing waves and color fields',
   E'느린 파동과 부드러운 색면을 탐구하는 생성 회화 시리즈입니다.',
   E'A generative painting series exploring slow waves and soft color fields.',
   true, true, 30, '{}'::jsonb)
on conflict (slug) do nothing;

-- 브랜드별 작품 12점씩 (썸네일 없음 → 앱 플레이스홀더)
insert into public.artworks (title, title_en, slug, summary, summary_en, media_type, width, height,
                             category_id, brand_id, is_published, is_featured, sort_order, created_on)
select
  b.name || ' #' || lpad(g::text, 2, '0'),
  b.name_en || ' #' || lpad(g::text, 2, '0'),
  b.slug || '-' || lpad(g::text, 2, '0'),
  b.name || ' 시리즈의 생성 작품',
  'A generative piece from the ' || b.name_en || ' series',
  'image', 600, (array[450,600,750,800,900])[1 + (g % 5)],
  (select id from public.categories order by sort_order offset (g % 6) limit 1),
  b.id, true, g = 1, g, current_date - (g * 3)
from public.brands b
cross join generate_series(1, 12) as g
where b.slug in ('terminal','hypeboy','graceful-wave')
on conflict (slug) do nothing;

-- 태그 연결 (결정적 분배)
insert into public.artwork_tags (artwork_id, tag_id)
select a.id, t.id
from public.artworks a
join lateral (
  select id from public.tags order by slug offset (abs(hashtext(a.slug)) % 9) limit 2
) t on true
where a.slug ~ '^(terminal|hypeboy|graceful-wave)-[0-9]{2}$'
on conflict do nothing;

-- 브랜드 대표 작품
update public.brands b set featured_artwork_id = a.id
from public.artworks a
where a.slug = b.slug || '-01' and b.featured_artwork_id is null;

-- 히어로 배너 (이미지 미지정 → 앱 플레이스홀더)
insert into public.banners (title, title_en, subtitle, subtitle_en, target_brand_id, button_text, button_text_en, sort_order)
select 'TERMINAL', 'TERMINAL', '코드와 빛이 교차하는 단말기 미학', 'Terminal aesthetics where code meets light',
       id, '브랜드 보기', 'View brand', 10
from public.brands where slug = 'terminal'
and not exists (select 1 from public.banners);

-- 사이트 설정
update public.site_settings set value = jsonb_build_object(
  'tagline',    '직접 만든 디지털 아트를 탐색하고, 후원하고, 소장하세요.',
  'tagline_en', 'Explore, support and collect original digital art.',
  'about',      E'MarisNova는 생성 예술과 실시간 렌더링 엔진으로 만든 디지털 아트 포털입니다.\n각 작품은 독립된 브랜드 페이지에서 소개됩니다.',
  'about_en',   E'MarisNova is a portal for digital art made with generative systems and real-time rendering engines.\nEvery work lives on its own brand page.',
  'contact_email', '',
  'social',     '{}'::jsonb,
  'community',  '[]'::jsonb
) where key = 'site' and value = '{}'::jsonb;
