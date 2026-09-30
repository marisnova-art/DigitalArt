# MarisNova — Digital Art Platform

디지털 아트 작품 포털 + 작품별 브랜드 페이지 + 관리자 대시보드.
단일 HTML(Vanilla JS) + Supabase(Auth · PostgreSQL · Storage · RLS) + Cloudflare Pages.

```
public/                   ← Cloudflare Pages 배포 폴더 (이 폴더만 공개됨)
  index.html              ← 앱 전체 (CSS · JS 포함, 약 230KB)
  _redirects              ← SPA 폴백 (/brand/terminal 같은 주소 새로고침 대응)
  _headers                ← 보안 헤더
  robots.txt
supabase/
  schema.sql              ← 테이블 · 인덱스 · 트리거 · 검색 RPC · RLS · Storage 정책
  seed.sql                ← 선택: 초기 데모 데이터 (브랜드 3 · 작품 36 · 배너 1)
samples/
  artworks-import-sample.csv / .json  ← 일괄 등록 예시
```

---

## 1. 5분 요약

1. Supabase 새 프로젝트 → SQL Editor에서 `supabase/schema.sql` 실행 → (선택) `seed.sql` 실행
2. `public/index.html` 상단 `CONFIG`에 **Project URL**과 **anon key** 입력
3. Cloudflare Pages에 `public/` 폴더 배포
4. 사이트에서 회원가입 → SQL Editor에서 본인을 관리자로 지정 (§5)
5. Supabase Auth의 Site URL / Redirect URLs에 배포 주소 등록, Google OAuth 설정 (§3)

`CONFIG`를 비워 두면 **데모 모드**로 열립니다. 상단에 "DEMO MODE" 띠가 항상 표시되고, 로그인·즐겨찾기·관리자 저장은 실행되지 않으며 "저장되지 않았다"는 오류를 명확히 보여줍니다.

---

## 2. Supabase 데이터베이스

### 실행
Dashboard → **SQL Editor** → `schema.sql` 전체 붙여넣기 → Run. 새 프로젝트에 1회 실행하는 마이그레이션입니다.

### 테이블

| 테이블 | 역할 |
|---|---|
| `user_roles` | 관리자 권한. **쓰기 정책 없음** → 브라우저에서 권한 상승 불가, SQL Editor에서만 부여 |
| `profiles` | 표시 이름 · 아바타 · 선호 언어 (가입 시 트리거가 자동 생성) |
| `artworks` | 작품 (KO/EN 제목·요약·설명, 썸네일/미리보기/비공개 원본 경로, 크기, 제작일, 공개·추천·정렬, 작품별 Gumroad/Redbubble, SEO, `deleted_at` 소프트 삭제) |
| `brands` | 브랜드 페이지 (로고·커버[이미지/영상], 대표 작품, 후원·Gumroad·Redbubble URL, SNS JSONB, 라이선스, KO/EN SEO) |
| `categories` / `tags` / `artwork_tags` | 분류. 태그는 다대다, 한글 태그 슬러그 허용 |
| `artwork_stats` | 즐겨찾기 수·조회수 (트리거/RPC만 수정, 클라이언트 쓰기 불가) |
| `banners` | 히어로 배너 (데스크톱/모바일 이미지, 배경 영상, 연결 브랜드 또는 외부 URL, 기간, 순서) |
| `favorites` | 회원 즐겨찾기 (user+artwork 유니크) |
| `site_settings` | 소개글 · SNS · 커뮤니티 링크 · 기본 공유 이미지 |
| `deletion_requests` | 회원 탈퇴 요청 |

### 검색 · 성능
- `search_text` 컬럼을 트리거가 자동 생성 (제목·설명·요약 KO/EN + 브랜드명 + 카테고리명 + 태그). 브랜드·카테고리·태그 이름을 바꾸면 관련 작품이 자동 갱신됩니다.
- `pg_trgm` GIN 인덱스 → `LIKE '%검색어%'` 부분 일치가 한글·영문 모두 인덱스를 탑니다. 여러 단어는 AND.
- `search_artworks()` RPC가 필터·정렬(최신/인기/이름)·페이지네이션(최대 60개)을 서버에서 처리하고, 비공개 브랜드 소속 작품을 제외합니다. 갤러리는 30개씩 무한 스크롤 + "더 보기" 버튼.
- 모든 URL 컬럼은 DB 제약으로 `https://`만 허용 (javascript: 등 차단). 슬러그는 `a-z0-9-` 형식 + 유니크.

### RLS 요약

| 대상 | 비로그인 | 회원 | 관리자 |
|---|---|---|---|
| 공개·미삭제 작품/브랜드 | 읽기 | 읽기 | 전체 읽기·쓰기 |
| 비공개/휴지통 작품·브랜드 | ✕ | ✕ | ✓ |
| 배너 | 활성+기간 내만 | 동일 | 전체 |
| profiles · favorites | ✕ | 본인 것만 | 본인 것만 |
| user_roles | ✕ | 본인 역할 조회만 | 조회만 (부여는 SQL) |
| Storage `public-media` | 공개 URL로 읽기 | 동일 | 업로드·수정·삭제 |
| Storage `originals` | ✕ | ✕ | 읽기·쓰기 (2분 서명 URL) |

> 스키마·시드·RLS는 PostgreSQL 16에 Supabase의 `auth`/`storage` 스키마를 흉내 낸 환경에서 실행 검증했습니다: 비로그인 쓰기 차단, 회원의 권한 상승·타인 프로필 수정·브랜드 링크 변조·스토리지 업로드 차단, 비공개 작품 태그 노출 차단, `javascript:` URL 거부, 슬러그 중복 거부, 즐겨찾기 카운트, 태그·브랜드명 검색 반영을 확인했습니다. 실제 Supabase 프로젝트에서 한 번 더 §9 체크리스트를 돌려 주세요.

---

## 3. Auth · Google OAuth 설정

### 공통 (Authentication → URL Configuration)
- **Site URL**: `https://<배포 도메인>` (예: `https://marisnova.pages.dev`)
- **Redirect URLs**에 추가:
  - `https://<배포 도메인>/**`
  - 로컬 테스트용 `http://localhost:8788/**` (필요 시)

### 이메일 가입
- Authentication → Providers → **Email**: 기본 활성. "Confirm email"을 켜면 가입 후 인증 메일 링크를 눌러야 로그인됩니다 (앱이 안내 메시지 표시).
- 비밀번호 재설정 메일 → `/account`로 돌아와 "새 비밀번호 설정" 창이 자동으로 열립니다.
- 기본 SMTP는 시간당 발송량이 매우 적습니다. 운영 전 Authentication → **SMTP Settings**에 자체 SMTP(Resend, SES 등)를 연결하세요.

### Google 로그인
1. [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → **OAuth consent screen** 구성 (앱 이름, 지원 이메일, 도메인)
2. **Credentials → Create credentials → OAuth client ID** → 유형 *Web application*
   - **Authorized JavaScript origins**: `https://<배포 도메인>`
   - **Authorized redirect URIs**: `https://<project-ref>.supabase.co/auth/v1/callback`
     (Supabase Dashboard → Authentication → Providers → Google 화면에 정확한 Callback URL이 표시됩니다)
3. Supabase → Authentication → Providers → **Google** 활성화 → Client ID / Client Secret 입력 → Save
4. 설정 전에는 버튼을 누르면 "Google 로그인이 Supabase에서 아직 활성화되지 않았습니다" 오류가 표시됩니다 (가짜 성공 없음).

앱은 PKCE 흐름을 사용하며, 로그인 후 주소창의 `?code=` 파라미터를 자동 정리합니다. Google 로그인은 `http(s)`로 배포된 주소에서만 동작합니다 (`file://`로 연 경우 안내 표시).

---

## 4. Storage

`schema.sql`이 버킷 2개와 정책을 만듭니다.

| 버킷 | 공개 | 용도 | 제한 |
|---|---|---|---|
| `public-media` | 공개 | 썸네일 · 미리보기 · 로고 · 커버 · 배너 | 50MB, jpg/png/webp/avif/gif/mp4/webm |
| `originals` | **비공개** | 고해상도 원본 | 앱 기준 500MB |

- 관리자 화면에서 이미지 업로드 시 기본으로 **WebP 변환 + 긴 변 1600px 리사이즈**(원본보다 커지면 원본 유지), 가로·세로 크기 자동 입력.
- 원본은 `originals`에 경로만 저장되고, 관리자만 2분짜리 서명 URL로 다운로드합니다.
- Free 플랜의 전역 업로드 한도는 50MB입니다. 더 큰 원본은 Pro 플랜에서 Storage 설정의 업로드 한도를 올리세요.
- 이미지 CDN: Supabase Storage 공개 URL은 CDN 캐시됩니다(`cache-control: 1년`). Pro 플랜이라면 Image Transformations로 AVIF/리사이즈 URL을 쓸 수 있습니다.

---

## 5. 최초 관리자 지정

1. 배포된 사이트에서 이메일 또는 Google로 가입·로그인
2. Supabase **SQL Editor**:
   ```sql
   insert into public.user_roles (user_id, role)
   select id, 'admin' from auth.users where email = 'you@example.com'
   on conflict (user_id) do nothing;
   ```
3. 새로고침 → 아바타 메뉴에 **관리자** 표시. 권한이 없는 계정으로 `/admin`에 들어가면 위 SQL과 본인 user id가 안내됩니다.

관리자 메뉴를 숨기는 것은 편의일 뿐, 모든 쓰기는 DB의 `is_admin()` RLS 정책이 최종 판단합니다.
관리자 해제: `delete from public.user_roles where user_id = '…';`

---

## 6. Cloudflare Pages 배포

### GitHub 연동 (권장)
1. 이 폴더를 GitHub 저장소로 push
2. Cloudflare Dashboard → Workers & Pages → Create → Pages → **Connect to Git**
3. Build 설정
   - Framework preset: **None**
   - Build command: *(비움)*
   - Build output directory: **`public`**
4. Deploy → `https://<프로젝트>.pages.dev` 발급 → `CONFIG.SITE_URL`과 Supabase Site URL/Redirect URLs, Google origins에 반영 후 다시 push

### 직접 업로드
Pages → Create → **Upload assets** → `public` 폴더를 드래그.

### CONFIG (public/index.html 상단)
```js
SUPABASE_URL: 'https://xxxx.supabase.co',
SUPABASE_ANON_KEY: 'eyJ… 또는 sb_publishable_…',   // anon 키만!
SITE_URL: 'https://marisnova.pages.dev',
```
- **service_role / sb_secret_ 키는 절대 넣지 마세요.** 앱이 해당 키를 감지하면 연결 자체를 거부합니다.
- anon 키는 공개돼도 되는 키입니다. 보안은 RLS가 담당합니다.
- `ALLOW_RUNTIME_CONFIG: true`면 푸터의 "연결 설정"에서 브라우저별로 URL/키를 넣어 테스트할 수 있습니다. 운영에서 원치 않으면 `false`.

### 라우팅
`/brand/terminal`, `/art/<slug>`, `/category/<slug>`, `/tag/<slug>`, `/discover?q=`, `/admin/...` 등 실제 경로를 씁니다. `_redirects`가 모든 경로를 `index.html`로 넘깁니다. `index.html`을 파일로 직접 열면 자동으로 `#/경로` 해시 모드가 됩니다.

---

## 7. 작품 일괄 등록 (관리자 → 일괄 등록)

1. CSV 또는 JSON 메타데이터 선택 (샘플: `samples/`, 관리자 화면에서도 다운로드 가능)
2. (선택) 썸네일 이미지를 여러 개 선택 — `thumbnail_file` 열의 파일명과 같은 파일이 업로드됩니다
3. **검증하기** → 오류 행(형식·중복 slug·없는 브랜드/카테고리·https 아님·파일 누락/크기/형식) 표시
4. **가져오기 실행** → 50개 단위 배치, 진행률, 실패 항목 목록

| 열 | 설명 |
|---|---|
| `slug` | 비우면 `title_en`/`title`로 생성. **같은 slug가 있으면 그 작품의 모든 필드를 덮어씀** |
| `title` (필수), `title_en`, `summary(_en)`, `description(_en)` | |
| `media_type` | `image` \| `video` |
| `thumbnail_url` / `thumbnail_file` | URL 직접 지정 또는 함께 선택한 파일명 |
| `preview_url`, `width`, `height` | |
| `brand_slug`, `category_slug` | 미리 만들어 둔 슬러그 |
| `tags` | CSV는 `a\|b\|c`, JSON은 배열. 없는 태그는 자동 생성. 열이 비어 있으면 기존 태그 유지 |
| `created_on` | `YYYY-MM-DD` |
| `is_published`, `is_featured` | `true/false`, `1/0`, `yes` (기본 false=비공개) |
| `sort_order`, `gumroad_url`, `redbubble_url`, `price_note`, `seo_title`, `seo_description` | |

한 번에 5,000행까지. 수천 개라면 파일을 나눠 여러 번 실행하세요.

---

## 8. SEO

- 페이지별 `title`, `description`, Open Graph, Twitter card, `canonical`, `og:locale`을 라우팅 시 갱신합니다. 브랜드는 KO/EN SEO 제목·설명·공유 이미지를 별도 관리합니다.
- `/admin`, `/account`, `/favorites`, 검색 결과는 `noindex`.
- **sitemap.xml**: 관리자 → 사이트 설정 → "sitemap.xml" 버튼이 공개된 브랜드·작품·카테고리로 생성 → `public/`에 넣고 재배포. `robots.txt`의 Sitemap 주소를 실제 도메인으로 바꾸세요.

**SPA 한계 (중요)**: 메타 태그를 JS로 바꾸므로 Google은 대체로 색인하지만, **카카오톡·X·Facebook 등 공유 미리보기 크롤러는 JS를 실행하지 않아** 모든 링크가 기본 메타로 보입니다. 브랜드별 공유 이미지가 SNS 미리보기에 반드시 떠야 한다면 다음 단계로:
- Cloudflare Pages **Functions**(`functions/brand/[slug].js`)에서 Supabase REST로 브랜드를 조회해 `HTMLRewriter`로 `<head>` 메타만 주입 (가장 적은 변경), 또는
- 빌드 시 브랜드/작품별 정적 HTML 생성(SSG).

---

## 9. 기능별 테스트 체크리스트

**데모 모드 (CONFIG 비움)**
- [ ] 상단 DEMO MODE 띠 표시, "Connect" 버튼으로 연결 설정 창
- [ ] 즐겨찾기 클릭 → "데모 모드에서는 저장되지 않습니다" 토스트
- [ ] 관리자 미리보기의 저장 버튼 비활성 + "저장되지 않습니다" 표시

**탐색**
- [ ] 홈: 히어로(배너 2개 이상이면 슬라이드·일시정지·점 네비), 갤러리 30개 → 스크롤 시 추가 로딩, 끝에서 "모든 작품을 불러왔습니다"
- [ ] 데스크톱 5열 / 태블릿 3–4열 / 모바일 2열, 가로 스크롤 없음
- [ ] 정렬 최신·인기·이름, 카테고리 서브내비, `/tag/<slug>`, 필터 칩 제거
- [ ] 검색: 제목·영문 제목·브랜드명·태그·설명으로 검색, 결과 없음 안내, `/` 키로 검색창 포커스
- [ ] 카드 클릭 → 브랜드 페이지 + 작품 상세 창(←/→로 이동, Esc 닫기, 주소 `?art=`), 링크 복사
- [ ] 우측 사이드바(인기·최근·추천 브랜드·SNS·소개) / 1280px 미만에서는 갤러리 하단으로 이동
- [ ] KO/EN 전환: UI·작품 제목·날짜·숫자 형식

**브랜드 페이지**
- [ ] `/brand/terminal` 직접 접속·새로고침 동작 (Cloudflare `_redirects`)
- [ ] URL이 비어 있는 후원/Gumroad/Redbubble/SNS 버튼은 표시되지 않음, 있는 것은 새 창 + `noopener noreferrer`
- [ ] 비공개 브랜드는 비로그인으로 404, 관리자는 "관리자 미리보기" 표시
- [ ] 커버 영상(mp4/webm)은 모션 감소 설정 시 이미지로 대체

**회원**
- [ ] 이메일 가입 → 인증 메일 → 로그인, 잘못된 비밀번호 오류 문구
- [ ] 비밀번호 재설정 메일 → 새 비밀번호 설정
- [ ] Google 로그인 → 돌아와서 로그인 상태, 주소창의 `?code=` 제거
- [ ] 새로고침 후에도 로그인 유지, 로그아웃
- [ ] 즐겨찾기 추가/해제 → `/favorites` 목록, 다른 기기에서도 동일
- [ ] 프로필 수정(이름·아바타 https·언어), 탈퇴 요청 → 관리자 화면에 표시

**관리자**
- [ ] 비관리자 `/admin` → 권한 없음 + 부여 SQL 안내
- [ ] 대시보드 통계·최근 등록/수정·외부 링크 현황
- [ ] 작품 등록(썸네일 업로드 → WebP·크기 자동 입력), 수정, 태그 입력, 공개/비공개 전환, 휴지통 → 복원 → 영구 삭제(확인 창)
- [ ] 원본 업로드(originals) → 다운로드 버튼으로 서명 URL
- [ ] `javascript:` / `http://` URL 저장 시 오류, 중복 슬러그 오류
- [ ] 브랜드: 대표 작품 슬러그, "작품 연결" 슬러그 목록, SNS, SEO
- [ ] 배너: 순서 위/아래, 활성 토글, 기간 지난 배너는 홈에서 사라짐
- [ ] 카테고리 순서 변경, 태그 생성·수정·삭제
- [ ] 일괄 등록 샘플 CSV 검증 → 가져오기 → 실패 항목 표시
- [ ] 사이트 설정 저장 → 푸터·소개·커뮤니티 반영, sitemap.xml/robots.txt 다운로드

**보안 (Supabase SQL Editor / 다른 브라우저)**
- [ ] 비로그인 상태에서 브라우저 콘솔로 `artworks` insert/update → RLS 오류
- [ ] 일반 회원으로 `user_roles` insert → 거부
- [ ] 비공개 작품 slug로 `/art/<slug>` 접근 → 404

**접근성**
- [ ] Tab만으로 헤더·카드·즐겨찾기·모달·드롭다운 조작, 포커스 링 표시
- [ ] "본문으로 건너뛰기" 링크, 모달 열리면 포커스 이동·Esc 닫기
- [ ] OS "동작 줄이기" 켜면 배너 자동재생·배경 영상·애니메이션 중지

---

## 10. 현재 한계 · 확장 포인트 (정직한 목록)

- **후원·판매는 외부 링크 방식**입니다. Gumroad/Redbubble 상품 정보·가격·구매 내역을 API로 가져오지 않으며, 가격 표시는 관리자가 입력한 문구입니다. 자체 결제를 붙일 때는 `commerceButtons()`(표시)와 `brands`의 후원 필드만 교체하면 됩니다.
- **회원 탈퇴**: 브라우저에는 service_role 키가 없으므로 관리자가 Dashboard → Authentication → Users에서 삭제합니다(프로필·즐겨찾기·요청은 cascade 삭제). 자동화하려면 service_role을 쓰는 Supabase Edge Function을 추가하세요.
- **조회수**는 상세 창을 열 때마다 +1 (중복 방지 없음). 인기순은 즐겨찾기 수 → 조회수 순.
- **SNS 공유 미리보기**는 §8의 Pages Functions 확장 전까지 기본 메타로 표시됩니다.
- **썸네일 없는 작품**은 슬러그 기반 추상 패턴 플레이스홀더로 표시됩니다 (실제 이미지를 가장하지 않도록 일관된 패턴 사용).
- 언어 추가: `L(ko, en)` 헬퍼와 `*_en` 컬럼 구조입니다. 3개 이상 언어로 늘릴 때는 `L()`을 키 기반 사전으로, 컬럼을 `translations jsonb`로 바꾸는 것을 권장합니다.
