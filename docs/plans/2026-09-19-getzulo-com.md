# getzulo.com — публичный сайт, документация и самообслуживание

**Цель:** запустить getzulo.com — витрину ZuloOne с полной документацией для клиентов,
аналитиков и разработчиков, и кнопкой «попробовать», которая за секунды выдаёт живой
тенант с демо-данными на 24 часа.

**ТЗ:** запрос пользователя + ответы на уточнения (языки, объём v1, вики, платежи).

---

## Контекст

Домен `getzulo.com` куплен, сайта нет. Сегодня у ZuloOne **нет ни одной публичной
поверхности**: ни лендинга, ни опубликованных доков, ни способа получить доступ без
оператора. При этом всё остальное уже зрелое — платформа, ферма тенантов на Traefik,
control plane с провижнингом, снапшотами и апгрейдами, ~200 тыс. слов документации.

Три вещи, которые это меняют:

1. **Продукт невидим.** Клиент не может ни прочитать, что это, ни потрогать.
2. **Каждый пилот — ручная работа оператора.** Тенант заводится кнопкой в панели.
3. **Доки заперты в приватном репозитории** и написаны для своих.

Итог v1: сайт на 4 языках, документация в двух зонах (клиентская + для разработчиков),
скриншоты, страница цен и **демо-тенант за один клик**. Приём платежей — этап 2;
архитектура под него закладывается сейчас, код не пишется.

### Что уже решено и не переигрывается

`zulo-deployment/prod/INSTALL.md:941` уже предписывает: getzulo.com живёт на

> **Изменение 2026-09-20.** Сайт переехал с Cloudflare Pages на собственный флот,
> за тот же Traefik, что маршрутизирует тенантов. Это отменяет Cloudflare Worker
> как обязательное звено: форма демо теперь может звать control plane внутри
> сети, без общего секрета, летающего через интернет. Пункты B14 и часть B10
> ниже написаны до этого решения и требуют пересмотра — оставлены как есть,
> чтобы было видно, что именно отменяется.

**Cloudflare Pages**, отдельно от origin'а — «чтобы публичный статический сайт не стоял
на машине, где крутятся базы клиентов». Апекс `zulo.one` и `www` уже припаркованы на
`192.0.2.1` под Redirect Rule на маркетинговый сайт (§7.1). План этому следует.

---

## Зафиксированные решения

| Решение | Значение | Почему так |
|---|---|---|
| Хостинг сайта | **Свой флот, за Traefik** (изменено 2026-09-20) | Со статики на Pages не дотянуться до control plane, и заявка на демо потребовала бы Cloudflare Worker с общим секретом через интернет. На флоте это вызов внутри сети — мост исчезает целиком. Цена: сайт лежит вместе с `zo-app-1`. `INSTALL.md` §7.0 переписан |
| Стек | Next.js 16 + next-intl 4 + Tailwind 4, `output: "export"` | Готовый внутренний шаблон — `d:\Sources\fistashion\next.config.ts`; тот же стек в `zulo.web/apps/site` |
| Доки | **Fumadocs** (MDX, App Router, i18n, статический поиск) | Сайдбар/TOC/поиск/i18n из коробки, один стек с витриной. Fallback, если упрётся в `output: export` — `@opennextjs/cloudflare` |
| Репозиторий | новый `getzulo/getzulo.com` | Отдельный CI, отдельный деплой-таргет; вики втягивается сборкой, не копируется |
| Языки витрины | **en (база), ru, ar (RTL), uk** | Ровно те же 4, что в SPA — `zulo.one/frontend/src/i18n/locales/` |
| Языки доков v1 | **ru (оригинал) + en (перевод)** | Вики — 45 тыс. слов по-русски; ar/uk в доках — этап 3 |
| Коммерческая модель | **SaaS-подписка на хостинг**, продукт закрытый | ZuloOne — коммерческий проприетарный продукт; исходники не публикуются |
| Платежи | Stripe | Внутренний прецедент: `zulo.life/services/payment-service` (Stripe 22, Checkout + вебхуки) |
| Демо-тенант | тёплый пул клонов golden-тенанта, TTL 24 ч | Провижнинг с нуля — ~5 минут и очередь; клон из снапшота — десятки секунд |
| Адрес демо | `demo-<6>.zulo.one` | Wildcard-сертификат и `ReservedSlugs` построены вокруг `zulo.one`; переезд на `*.getzulo.com` — не сейчас |

### Факты, проверенные в коде (несколько опровергают «очевидное»)

- **Control plane УЖЕ доступен из интернета** — `zulo-deployment/prod/mikrotik-firewall.rsc:178`
  пропускает Cloudflare-диапазоны на `10.10.0.200:8443`, а чек-лист §48 содержит
  `https://cp.zulo.one/ — panel, via Cloudflare`. Утверждение «CP недостижим извне» в
  `ARCHITECTURE.md` §4.1 **устарело и подлежит правке** (задача B17). Это меняет выбор
  моста: не нужен outbound-poll, нужен узкий anonymous-эндпоинт.
- **`/health` — не единственный анонимный эндпоинт.** `Api/InfraController.cs:404`
  (`POST /api/infra/report`) — `[AllowAnonymous]` + shared-token через
  `CryptographicOperations.FixedTimeEquals` + **503, когда токен не настроен**. Это
  готовый, уже обжитый шаблон для публичного моста — копируем его форму дословно.
- **В CI control plane нет `dotnet test`** и нет `.sln` — семь тестовых файлов не
  компилируются на CI вообще. Любой новый unit-тест — декорация, пока не сделана B16a.
- **`RestoreJobHandler` уже строит одноразовый тенант из снапшота** и при этом **не
  зовёт `auth/setup` и не шлёт инвайт** — пользователи приезжают внутри дампа. Значит
  демо-клону не нужны ни SMTP, ни `TenantInviteService`.
- **Тенанты сейчас работают без лимитов**: `appsettings.json` ставит
  `MemoryLimitBytes: 0` и `CpuLimit: 0`, а `CpuLimit` вообще отсутствует в
  `SettingsCatalog`. Для демо это критично — см. риск R1.
- **Ни одного скриншота в доках.** `wiki` + `docs`: 0 картинок, 0 ссылок на картинки.
  Единственные PNG в репозитории — 14 артефактов Playwright в
  `zulo.one/frontend/e2e/__screens__/`.
- **Вики — 56 файлов / 7 462 строки / ~55 тыс. слов, почти целиком по-русски**
  (исключение: `wiki/business/mobile.md` — на английском). Переводных пар нет,
  i18n-инфраструктуры в доках нет.
- **Нет `Warehouse`/`Store` модели** (Store — справочник внутри Inventory) и **нет
  модели `SalesAgent`** (это роль мобильного клиента). На страницу «Модули» идут
  **13 бизнес-моделей**: Common, Organization, Accounting, Tax, Inventory, Purchasing,
  Sales, Production, HR, CRM, Costing, GLIntegration + 2 локализации.

---

## Трек A — Сайт и контент

Репозиторий `getzulo/getzulo.com`, pnpm, структура по образцу `zulo.web`.

```
getzulo.com/
├─ src/app/[locale]/           # витрина: /, /product, /modules, /pricing, /demo, /contact, /legal/*
├─ src/app/[locale]/docs/      # Fumadocs: клиентская зона
├─ src/app/[locale]/dev/       # Fumadocs: зона разработчика (вики as-is)
├─ src/i18n/locales.ts         # СКОПИРОВАТЬ из zulo.web/apps/site/src/i18n/locales.ts
├─ messages/{en,ru,ar,uk}.json # строки витрины
├─ content/docs/{ru,en}/       # клиентские доки (пишутся)
├─ content/dev/{ru,en}/        # ← синхронизируется из zulo.one/wiki, НЕ редактируется руками
├─ public/shots/<locale>/      # ← артефакт Playwright из zulo.one CI
└─ scripts/sync-wiki.mjs       # втягивание + allow/deny-лист
```

### A1. Каркас, i18n, RTL, деплой

**Файлы:** `next.config.ts` (`output: "export"`, `trailingSlash: true`, `images.unoptimized: true`,
обёртка `withNextIntl` — дословно из `fistashion/next.config.ts`), `src/i18n/routing.ts`
(`defineRouting`, `localePrefix: 'always'`), `src/i18n/locales.ts`,
`.github/workflows/deploy.yml`.

`src/i18n/locales.ts` **копируется** из `zulo.web/apps/site/src/i18n/locales.ts` — там уже
решены `dir: 'rtl'` для `ar`, `RTL_LOCALES`, `localeDir()`, нативные имена и OG-коды. Набор
урезается до `en|ru|ar|uk`. В корневом layout — `<html lang={locale} dir={localeDir(locale)}>`.

Деплой: self-hosted runner `zo-ci-1` (org на GitHub Free — бережём минуты), `pnpm build`
→ `docker build` → реестр `10.10.0.210:5000` → `docker compose … up -d site` на `zo-app-1`.
Нужен второй Origin-сертификат на `getzulo.com` (wildcard покрывает только
`*.zulo.one`) и раннер, зарегистрированный на этот репозиторий. Прежние секреты
`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` больше не нужны; было — в
GitHub Environment `production`. Прод — только `workflow_dispatch` + push в `main`,
как в `zulo.web/.github/workflows/deploy-site-prod.yml`.

**Наблюдаемо:** `https://getzulo.com/en` и `/ar` отдают 200; в `/ar` у `<html>` стоит
`dir="rtl"`; `curl -sI https://zulo.one/` → 301 на getzulo.com (Redirect Rule на edge).

### A2. Конвейер документации и гейт «не опубликовать внутреннее»

**Файлы:** `scripts/sync-wiki.mjs`, `content/dev/.gitignore`, `.github/workflows/sync-docs.yml`.

Синхронизация, а не копипаста: workflow чекаутит `getzulo/zulo.one` по PAT, прогоняет
`sync-wiki.mjs`, коммитит `content/dev/ru/**`. В `zulo.one` добавляется шаг, который на
изменение `wiki/**` шлёт `repository_dispatch` в сайт-репозиторий — доки переиздаются сами.

**Allow-лист (публикуется):** `wiki/user/**`, `wiki/business/**` (кроме `roadmap.md`),
`wiki/developer/**`, `docs/WORKSPACE.md`, `docs/architecture/{Core.Architecture,Database.Schema,Testing.Architecture}.md`,
`docs/samples/UniversalERP/**`, `zuloone-workspace/.claude/skills/**` → раздел «Рецепты».

**Deny-лист (сборка ПАДАЕТ, если файл просочился):** `wiki/business/roadmap.md`
(8 437 слов внутреннего статуса стройки), `docs/superpowers/**` (40 799 слов),
`docs/decisions/**`, `docs/GAP_ANALYSIS.md`, `docs/MIQS-PARITY.md`, `.superpowers/**`.
Эти документы рекламируют дыры, незаконченное и сравнение с предшественником MIQS.

Гейт — отдельный шаг CI, а не «внимательность»: один случайно синхронизированный
`roadmap.md` публикует список всего, что не работает.

**Наблюдаемо:** `pnpm sync:wiki && pnpm build` — в `out/ru/dev/` лежат 55 страниц;
подложить `roadmap.md` руками → сборка падает с именем файла.

### A3. Клиентская зона доков

**Файлы:** `content/docs/ru/**` (пишется), `content/docs/en/**` (перевод),
`src/app/[locale]/docs/[[...slug]]/page.tsx`.

Вики писалась для своих — клиенту она тяжела. Поверх пишется тонкий слой:
- **Начало работы** — что такое тенант, первый вход, интерфейс (на базе `wiki/user/getting-started.md`)
- **Модули** — 13 страниц из `wiki/business/overview.md` (там уже таблица «модуль → роль в бизнесе»)
- **Сценарии** — «продажа от заказа до денег», «приход и себестоимость», «ЗП», «ЗАТСА-инвойс»
- **Локализации** — Саудовская Аравия (ZATCA/FATOORA), Украина
- **Мобильный клиент** — `wiki/business/mobile.md` уже на английском, идёт почти как есть

Каждая страница переиспользует существующий текст, а не пишется с нуля. Переключатель
языка на непереведённой странице честно говорит «пока доступно на русском».

**Наблюдаемо:** `/en/docs` и `/ru/docs` отдают сайдбар с одинаковым деревом; поиск по
слову «FIFO» находит страницу себестоимости.

### A4. Скриншоты — из Playwright, а не руками

**Файлы:** `zulo.one/frontend/e2e/shots.spec.ts` (расширить существующий набор),
`zulo.one/.github/workflows/ci.yml` (публикация артефакта), `getzulo.com/public/shots/`.

Скриншоты, снятые руками, протухают за спринт. В `zulo.one/frontend/` уже есть
Playwright (`playwright.config.ts`, `e2e/`, 14 PNG в `e2e/__screens__/`) — набор
расширяется прогоном по **golden-тенанту** (трек B) в каждой из 4 локалей: дашборд,
список документов, карточка счёта, дизайнер форм, риббон, тёмная тема, RTL-вид.
Артефакт забирает сайт-репозиторий тем же `repository_dispatch`.

**Наблюдаемо:** `public/shots/ar/dashboard.png` существует и на нём интерфейс справа
налево; на странице `/ar/product` он отрисован.

### A5. Витрина

**Файлы:** `src/app/[locale]/page.tsx`, `product/`, `modules/`, `pricing/`, `contact/`,
`messages/{en,ru,ar,uk}.json`.

Источники текста (не выдумывать, переиспользовать):

| Страница | Откуда |
|---|---|
| Главная / питч | `zulo.one/README.md:3-12` (английский элеватор-питч), `wiki/README.md:17-22` (русский) |
| «Что умеет» | `zulo.one/README.md:79-90` — 7 буллитов, уже маркетинговой формы |
| Модули | `wiki/business/overview.md:9-24` — таблица «модуль → роль в бизнесе» |
| Принципы | `wiki/business/product-direction.md:11-24` + раздел «чего мы намеренно не делаем» (112-121) |
| Возможности | `wiki/business/process-status.md:26-54` — матрица 24 процессов, **курированное подмножество**: публиковать целиком — публиковать и все пробелы |
| Слои/кастомизация | `README.md:24-26` — `System → Base → Solution → Customization → User` |

Бренд-токены уже есть: `#16372c` (forest), `#0d2849` (navy), `#2969c0` (accent) —
`zulo.one/frontend/src/kit/brand.ts`.

**Правило по локалям (важно):** прежде чем добавлять строку в `messages/ar.json` или
`uk.json` — свериться с формулировками в `zulo.one/frontend/src/i18n/locales/{ar,uk}.ts`
(3 185 и 3 226 строк). Термины продукта должны совпадать с теми, что человек увидит,
войдя в тенант.

**Наблюдаемо:** Lighthouse ≥ 95 по Performance и SEO на `/en`; все 4 локали без
непереведённых ключей (тест по образцу `frontend/src/i18n/locales.test.ts`).

### A6. Цены и юридические страницы

**Файлы:** `src/app/[locale]/pricing/page.tsx`, `src/app/[locale]/legal/{terms,privacy,dpa,sla,subprocessors}/page.tsx`.

v1 показывает тарифы SaaS-подписки с ценой «от», кнопку демо и форму «обсудить».
Checkout'а нет — он в треке C.

Продукт **закрытый и коммерческий**; «открытым кодом» его на сайте не называть.
Переносимость продавать можно и нужно, но ровно ту, которая есть: данные и
конфигурация выгружаются, кастомизация — метаданные и переезжает между стендами
клиента. Это не право развернуть платформу самому.

**Юридическое — блокирует сбор e-mail'ов, не только платежи:** Privacy Policy (GDPR для
EU + PDPL для Саудовской Аравии), Terms, DPA, SLA, список субпроцессоров. Форма демо
собирает e-mail — без Privacy Policy её нельзя открывать.

**Наблюдаемо:** `/en/legal/privacy` существует и слинкован из футера и из формы демо.

### A7. Форма демо на сайте

**Файлы:** `src/app/[locale]/demo/page.tsx`, `src/components/DemoForm.tsx` (React-остров),
`src/lib/demo.ts`.

Поля: e-mail, компания (необязательно), Turnstile. Три исхода — `ready` (URL + логин +
пароль на экране, с обратным отсчётом до `expiresAtUtc`), `queued` (поллинг по
`requestId`), `duplicate`/`tooMany`/`full` (человеческий текст, не код ошибки).
Контракт — задача B10.

**Наблюдаемо:** с живого сайта форма возвращает URL; переход по нему пускает в ZuloOne
под выданным паролем.

---

## Трек B — Демо-тенант за один клик

Полностью в `d:\Sources\zulo-control-plane`, кроме B15 (воркспейс) и B14/B17
(Cloudflare и `zulo-deployment`).

**Форма решения.** Golden-тенант `showcase.zulo.one` — обычный тенант оператора с моделью
`DemoData`. Джоб `DemoTemplate` снимает с него снапшот и благословляет его как шаблон.
**Тёплый пул** из 2 готовых демо поддерживается одним hosted-сервисом, который клонирует
шаблон через вынесенный из `RestoreJobHandler` `TenantCloneService`. Посетитель попадает
на **Cloudflare Worker**, тот проверяет Turnstile и зовёт token-gated `[AllowAnonymous]`
эндпоинт на `cp.zulo.one`, скроенный по образцу `POST /api/infra/report`. Эндпоинт
**атомарно занимает** демо из пула одним `UPDATE … WHERE Id = (SELECT … FOR UPDATE SKIP
LOCKED) RETURNING`, сбрасывает пароль, ставит `ExpiresAt = now + 24h` и отдаёт URL с
кредами в том же ответе. Тот же сервис жнёт просроченное через существующий
`TenantProvisioner.DeleteAsync`.

| # | Задача | Ключевые файлы | Наблюдаемо |
|---|---|---|---|
| **B1** | Схема: `TenantDemo {Golden,Pooled,Claimed}`, `ExpiresAt`, `ClaimedAt`, `DemoRequestId` на `Tenant`; таблица `DemoRequest` | `Registry/Tenant.cs`, `Registry/DemoRequest.cs`, `Registry/ControlPlaneDbContext.cs`, `Registry/Migrations/20260920090000_AddDemoTenants.cs` + **правка `ControlPlaneDbContextModelSnapshot.cs` руками** (`dotnet-ef` на машине нет) | `\d "Tenants"` показывает колонки; `GET /api/tenants` — форма ответа **не изменилась** |
| **B2** | Группа настроек `Demo workspaces` (17 ключей) + `Demo:RequestToken` **вне каталога**, только из `cp.env` — как `Patroni:ReportToken` | `Settings/SettingsCatalog.cs`, `Provisioning/Demo/DemoSettings.cs`, `Provisioning/Demo/DemoConfig.cs` | `/api/settings` отдаёт группу; `grep -ci requesttoken` → `0`. **`web/src/Settings.tsx` не меняется** |
| **B3** | `ContainerLimits(MemoryBytes, Cpu, PidsLimit)` в `TenantContainerService.RunAsync` | `Provisioning/TenantContainerService.cs` + 6 вызовов | `docker inspect` демо: `805306368 1000000000 256`; у `t1` — `0` |
| **B4** | **Чистый рефакторинг:** `TenantCloneService` вынесен из `RestoreJobHandler` | `Provisioning/TenantCloneService.cs`, `Jobs/RestoreJobHandler.cs` | Лог джоба Restore **побайтно совпадает** с логом до коммита |
| **B5** | Политика статиками: `DemoSlug`, `DemoQuota.Decide(...)`, `DemoLifetime.IsReapable(...)`; `RegisterAsync` запрещает префикс `demo-` | `Provisioning/Demo/*.cs`, `Provisioning/TenantProvisioner.cs`, 3 файла тестов | `dotnet test` — ~25 фактов; `POST /api/tenants {"slug":"demo-acme"}` → 400 |
| **B6** | `DemoPool.TryClaimAsync` — один `UPDATE … FOR UPDATE SKIP LOCKED`; `ResetPasswordAsync` получает `mustChangePassword = false` | `Provisioning/Demo/DemoPool.cs`, `Provisioning/TenantAdminService.cs` | 5 параллельных запросов при пуле 2 → ровно 2 `ready` с **разными** URL, 3 `queued`; ни один `DemoRequestId` не повторяется |
| **B7** | `JobKind.DemoProvision` — собрать одно демо из шаблона; пароль рандомизируется **на сборке** | `Jobs/DemoProvisionJobHandler.cs`, `Jobs/Job.cs` | Джоб `Succeeded`, шаг `Pooled at https://demo-k7m2xq.zulo.one`; `curl -sI` → 200 |
| **B8** | `JobKind.DemoTemplate` + `SnapshotWriter` — снять снапшот golden, записать `Demo:TemplateSnapshotId`, протухшие `Pooled` пересобрать. **`Claimed` не трогать** | `Jobs/DemoTemplateJobHandler.cs`, `Snapshots/SnapshotWriter.cs` | `Demo:TemplateSnapshotId` в настройках, дамп на томе |
| **B9** | `DemoPoolService` — жатва + пополнение. **Жатва НЕ через `JobChannel`** (он строго последовательный, апгрейд держит его часами); пополнение — через. Перезапуск-безопасность из колонки, а не из строки джоба | `Provisioning/Demo/DemoPoolService.cs`, `DemoNudge.cs` | Просрочить демо → через 70 с нет контейнера, тома, БД, роли, mongo-журнала; **`showcase` с просроченным `ExpiresAt` остаётся жив** |
| **B10** | Публичный мост: `POST/GET /api/demo/request` — `[AllowAnonymous]` + `X-Demo-Token` через `FixedTimeEquals` + **503, когда не настроен** | `Api/DemoController.cs`, `Provisioning/Demo/DemoToken.cs`, `Program.cs` (лимитер `demo-request`) | Без токена → 503; с чужим → 401; с верным → `ready` + рабочий пароль; `/api/tenants` по-прежнему 401 |
| **B11** | Операторский API: обзор, убить, продлить, слить пул, пересобрать шаблон | `Api/DemoAdminController.cs` | `/api/demo/admin/overview` без креда → 401 |
| **B12** | Регистрация в DI | `Program.cs` | С `Demo:Enabled=false` в логе нет демо-активности вообще |
| **B13** | Панель: страница `Demos`, бейдж `demo` в списке тенантов, карточка на Overview | `web/src/Demos.tsx`, `App.tsx`, `Tenants.tsx`, `Overview.tsx`, `api.ts` | `npm run build && npm run lint` чисто; шесть одноразовых тенантов больше не выглядят как клиенты |
| **B14** | Cloudflare: Worker на `demo.getzulo.com`, Turnstile, Access **Bypass** строго на `/api/demo/*` | `demo-worker/src/index.ts`, `wrangler.toml` | `POST cp.zulo.one/api/demo/request` → **401 от приложения** (не 302 от Access), `GET /api/tenants` → 302/401 |
| **B15** | **Датасет** — модель `DemoData` в воркспейсе: компания, ~24 контрагента, ~60 номенклатур, цены, начальные остатки, ~200 продаж и ~40 закупок за 12 месяцев | `zuloone-workspace/DemoData/model.json` + `DataPackages/*.json` | Дамп **< 50 МБ**; `DemoProvision` — десятки секунд, не минуты |
| **B16** | **Сначала завести `.sln` и `dotnet test` в CI** (их нет), потом тесты; расширить secret-grep на `adminPasswordOnce`/`logPassword` | `.github/workflows/ci.yml`, `ZuloOne.ControlPlane.sln` | Smoke: без токена 503, с чужим 401, с верным 202 (**не 500** — это проверка миграции), админский обзор 401 |
| **B17** | Документация деплоя: §4.1 `ARCHITECTURE.md` **исправить** (CP достижим через Cloudflare), §7.5 `INSTALL.md` «No Workers» → «один Worker, вот почему это не дыра», арифметика ёмкости `zo-app-1` | `zulo-deployment/prod/{ARCHITECTURE,INSTALL}.md`, `.env.example` | Доки описывают то, что реально стоит |

**Порядок и точка остановки.** B1→B4 не трогают публичную поверхность и откатываются по
одной. B5→B9 собирают движок: **после B9+B11+B13 фича работает целиком из панели
оператора, без единого публичного эндпоинта.** Здесь надо остановиться и неделю выдавать
демо руками. Не потерял ли жнец контейнер, не поплыл ли пул — и только потом B10/B14
открывают дверь. B15 идёт параллельно с первого дня: другой репозиторий, другой человек.
B16 обязан лечь **вместе с B5**, иначе тесты — декорация.

---

## Трек C — Приём платежей (этап 2, не сейчас)

Закладывается, но не пишется:

- Колонка `Tenant.Plan` уже существует и уже на проводе (`TenantsController.Summary:622`,
  `web/src/api.ts:122`) — её никто не читает; она станет носителем тарифа.
- `ReservedSlugs.cs:63-64` уже резервирует `billing`, `invoice`, `payment`, `checkout`,
  `subscribe`, `subscription`.
- `ExpiresAt` (B1) спроектирован так, чтобы его переиспользовал платный триал:
  `Demo = null` + `ExpiresAt` = конец триала.
- Прецедент интеграции — `zulo.life/services/payment-service`: Stripe Checkout Session,
  вебхук, миграции `AddStripeCheckoutSession`. Переиспользуется форма, не код (другой
  стек — NestJS).
- Путь: Stripe Checkout на сайте → вебхук на Worker → тот же token-gated мост
  (`POST /api/tenants` вместо `/api/demo/request`) → провижнинг обычного тенанта с
  `Plan` и без `ExpiresAt`.

---

## Риски

**R1 — демо-тенант это Roslyn в руках незнакомца.** ZuloOne компилирует C# тенанта на
лету. Самообслуживание означает, что чужой человек получает редактор скриптов, коннект к
Postgres и процесс на `zo-app-1` — хосте, где живут Traefik и все платящие тенанты. А
лимиты сейчас нулевые (`MemoryLimitBytes: 0`, `CpuLimit: 0`). Поэтому B3 (память, CPU,
`PidsLimit`) — не оптимизация, а предусловие B10, и `container-egress.sh` надо
перепроверить именно на демо-контейнере до открытия двери. `ProductModelDevMode` на демо
обязан быть `false` (по умолчанию так — добавить утверждение, не правку).

**R2 — демо в пуле достижимо до того, как его кто-то попросил.** Клон несёт хеши паролей
golden-тенанта: `demo-k7m2xq.zulo.one` живёт, публичен и принимает пароль из дампа.
Поэтому пароль рандомизируется дважды — при сборке (B7) и при выдаче (B6).

**R3 — переводы доков.** 45 тыс. слов × язык. v1 намеренно ограничен ru+en. Машинный
перевод ar/uk без ревью носителем даст кальки — та же ошибка уже была на локалях SPA.
Этап 3 планировать с ревью, а не с объёмом.

**R4 — два бренда в одном потоке.** Клиент покупает на `getzulo.com`, а тенант получает
на `*.zulo.one`. Для v1 это принимается (wildcard-сертификат, `ReservedSlugs` и Traefik
построены вокруг `zulo.one`), но на странице демо это надо объяснить одной строкой, а не
оставить как сюрприз.

**R5 — в репозитории закрытого продукта лежит GPL v3.** `zulo.one/LICENSE` — дословный
текст GNU GPL v3 на 674 строки, и `README.md:128` ссылается на него разделом «License».
Продукт при этом коммерческий и закрытый. Это не расхождение в документации: файл
лицензии сам по себе является предоставлением прав, и всякий, кто законно получил копию
кода вместе с ним — подрядчик, сотрудник, аудитор, — может ссылаться на GPL, включая
право распространять дальше. Разобрать до первой внешней выдачи кода; у воркспейса
лицензии нет вообще, её тоже надо назвать. Решение юридическое, не инженерное.

**R6 — доки разъедутся с кодом.** Поэтому A2 — синхронизация из `zulo.one/wiki`, а не
копия. Вторая копия текста проживёт ровно до первого рефакторинга.

---

## Проверка целиком

Сквозной сценарий, который должен пройти до объявления v1 готовым:

1. **Сайт:** `https://getzulo.com/{en,ru,ar,uk}` — 200; `/ar` в RTL; `https://zulo.one/` → 301 на getzulo.com.
2. **Доки:** `/ru/dev` содержит 55 страниц вики; deny-лист работает (подложить `roadmap.md` → сборка падает).
3. **Скриншоты:** `public/shots/ar/dashboard.png` снят Playwright'ом с golden-тенанта, не руками.
4. **Пул:** `GET /api/demo/admin/overview` → `2 pooled · 0 claimed · 2/6`.
5. **Демо:** форма на сайте → Turnstile → Worker → `cp.zulo.one` → ответ `ready` с URL и паролем **менее чем за 5 секунд**.
6. **Вход:** по выданному URL и паролю — рабочий ZuloOne с заполненными продажами и непустыми дашбордами.
7. **Жатва:** `update "Tenants" set "ExpiresAt"=now()` → через 70 секунд нет контейнера, тома, базы, роли и mongo-журнала.
8. **Golden неприкосновенен:** та же операция над `showcase` → тенант жив.
9. **Панель закрыта:** `GET https://cp.zulo.one/api/tenants` без креда → 302/401, никогда 200.
10. **Секреты не текут:** CI-grep по `/api/demo/*` не находит `databasePassword|jwtSigningKey|adminPasswordOnce|logPassword`.

---

## Куда положить этот план

Файл скопировать в `d:\Sources\zulo-deployment\docs\plans\2026-09-19-getzulo-com.md` —
трек B меняет control plane и деплой, а `zulo-deployment` уже хранит `INSTALL.md` и
`ARCHITECTURE.md`, которые этот план правит. Задача B15 (модель `DemoData`) дополнительно
требует своего плана по скилу `zuloone-writing-plans` с выданными `metaId` — датасет
заводит объекты в воркспейсе, и без таблицы GUID'ов исполнитель придумает свои.
