<h1 align="center">Claude Studio</h1>

<p align="center">
  <b>Projelerin için tek ekran — Claude oturumları, beceriler, zamanlanmış çalışmalar, servisler ve terminaller.</b><br>
  Visual Studio gibi klasör açarsın; gerisi tek pencerede.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/UI-SwiftUI-purple" alt="SwiftUI">
</p>

---

## Ne yapar

**Klasör aç, çalışmaya başla.** Açılışta son projelerin listelenir; birini seçersin, pencere o projenin stüdyosuna dönüşür. Her proje kendi penceresinde yaşar.

| Panel | İçerik |
|---|---|
| **claude** | Claude Code oturumların. tmux ile kalıcı — uygulamayı kapat, yarın aç, oturum kaldığı yerden devam eder. Oturumu üstten çift tıklayıp adlandırırsın; kapattığında bile kaydı kalır ve **+ → önceki oturumlar** altından aynı isimle, aynı konuşmayla (`claude --resume`) geri gelir. Claude sırayı sana verdiğinde nokta yanar ve tek bir yumuşak ton duyulur. |
| **beceriler** | Projenin `.claude/skills` klasöründeki beceriler (skills) (ve gölgelenmeyen genel skill'ler). Tanımını okur, oturumda ya da arka planda çalıştırır, zamanlarsın. |
| **cron** | Zamanlanmış beceri çalışmaları; her koşunun tarihi, durumu ve **ürettiği çıktı**. launchd'ye bağlıdır: uygulama kapalıyken de çalışır. |
| **servis** | `npm run dev`, `php artisan serve`, worker'lar… Başlat/durdur/yeniden başlat, port farkındalıklı durum, açılışta otomatik başlatma. |
| **terminal** | Elle açtığın kabuklar. Bunlar da tmux destekli; geçmişleri kaybolmaz. |

Sekmeler arası geçiş bedelsizdir: terminal görünümleri bellekte yaşar, sekme değiştirmek yalnız hangi görünümün ekleneceğini seçmektir — süreç, kaydırma konumu ve tampon dokunulmaz kalır.

## Kurulum

Hazır paketi [Releases](https://github.com/ocracy/claude-studio/releases) sayfasından indir,
`Claude Studio.app`'i `/Applications`'a taşı ve karantinayı temizle (ad-hoc imzalı):

```bash
xattr -cr "/Applications/Claude Studio.app" && open -a "Claude Studio"
```

Ya da kaynaktan:

```bash
brew install tmux          # kalıcı oturumlar için gerekli
git clone https://github.com/ocracy/claude-studio && cd claude-studio
./install.sh               # derler ve /Applications'a kurar
```

### Güncelleme

Uygulama açılışta yeni sürüm var mı diye bakar; varsa üst barda **Güncelle** rozeti çıkar.
**Ayarlar → Hakkında**'dan da elle denetleyebilirsin: indirir, paketi değiştirir ve kendini
yeniden başlatır.

Bir projeyi doğrudan açmak:

```bash
open -a "Claude Studio" ~/dev/projem
```

## Proje ayarları: `.cs/`

Visual Studio'nun `.vs` klasörü gibi, her projenin ayarları kendi içinde durur:

```
<proje>/
├── .claude/skills/…        # beceriler (Claude Code'un kendi düzeni; dokunulmaz)
└── .cs/
    ├── services.json       # servisler          ← paylaşılabilir
    ├── schedules.json      # zamanlanmış çalışmalar ← paylaşılabilir
    ├── terminals.json      # terminaller        ← paylaşılabilir
    ├── sessions.json       # Claude oturum kayıtları (makineye özel)
    ├── settings.json       # arayüz tercihleri  (makineye özel)
    └── runs/<skill>/       # çalışma raporları (.md) + .state.json
```

Her bölüm kendi dosyasında: servis listesini ekiple paylaşırken pencere genişliğin o dosyayı
kirletmez. Dosyalar insan tarafından okunur ve elle düzenlenebilir.

```json
// .cs/services.json
[
  { "name": "frontend", "command": "npm run dev", "port": 5173, "autoStart": true }
]
```

```json
// .cs/schedules.json
[
  { "skill": "release-notes", "frequency": "daily", "hour": 2, "minute": 0, "enabled": true }
]
```

## Beceriler ve çalışma raporları

Beceriler Claude Code'un kendi biçiminde okunur — dönüştürme yok:

```
.claude/skills/<ad>/SKILL.md     ya da     .claude/skills/<ad>.md
```

Bir beceri çalıştırıldığında ortamına şunlar verilir:

| Değişken | Anlamı |
|---|---|
| `CS_REPORT_FILE` | Raporun yazılacağı dosya |
| `CS_RUN_DIR` | Bu becerinin rapor klasörü |
| `CS_RUN_MODE` | `manual` \| `scheduled` |
| `CS_LAST_REPORT`, `CS_LAST_STATUS`, `CS_LAST_SUMMARY` | Önceki çalışmanın bağlamı |

Rapor bir frontmatter ile başlar; uygulama listeyi bundan kurar:

```markdown
---
run_at: 2026-08-17T02:00:00Z
status: ok          # ok | warning | failed
summary: 12 PR özetlendi, uyarı yok
duration_sec: 8
---
```

Ayrı bir veritabanı yoktur — **raporların kendisi durumdur**. launchd uygulama kapalıyken rapor üretse bile, açılışta hiçbir eşitleme gerekmeden doğru tablo görünür.

## Kısayollar

| | |
|---|---|
| ⌘O | Klasör aç |
| ⇧⌘N | Yeni pencere |
| ⌘N | Yeni Claude oturumu |
| ⌘T | Yeni sekme (Claude sekmesindeysen oturum, değilse terminal) |
| ⇧⌘T | Yeni terminal |
| ⌘, | Ayarlar |
| ⌘W | Sekmeyi kapat |
| ⇧⌘] / ⇧⌘[ | Sonraki / önceki sekme |

## Çok satırlı girdi

tmux içinde `/terminal-setup` çalışmaz; eşleme uygulamanın kendisinde yapılıdır:
**Shift+Enter** ve **Option+Enter** yeni satır ekler.

## Ayarlar (⌘,)

Ses açık/kapalı ve hangi ses, çalışma bitince ses, bildirim balonu, Dock rozeti, terminal yazı
tipi boyutu, açılışta son oturuma bağlanma.

## Mimari

- **Swift 6 · SwiftUI · [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) · tmux · launchd** — Electron yok, telemetri yok, her şey yerel.
- `Core/` iş mantığı (`TerminalEngine`, `Tmux`, `Scheduler`, `SkillStore`, `ProjectConfig`), `Views/` yalnız sunum.
- Hangi oturumun **yaşadığı** tmux'tan okunur (tek doğruluk kaynağı); oturumun **adı ve konuşma kimliği** `.cs/config.json`'da durur, böylece kapattığın oturum ismiyle geri gelir.
- Bildirim için `osascript` kullanılır: ad-hoc imzalı bir uygulamada `UNUserNotificationCenter` güvenilir değildir.

## Claude Code hook'ları

Bir oturumun "çalışıyor / seni bekliyor" durumunu görebilmek için `~/.claude/settings.json`'a bir hook eklenir (idempotent, mevcut hook'lara dokunmadan). Script Claude Studio dışında hiçbir şey yapmaz: `CS_TAB_ID` tanımlı değilse anında çıkar — diğer Claude oturumlarına sıfır etki.
