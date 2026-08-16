# CLAUDE.md

Bu dosya Claude Code için proje rehberidir.

## Proje Özeti

**Claude Studio** — çok projeli geliştirme stüdyosu (macOS, Swift 6 + SwiftUI + SwiftTerm).
Klasör açılır, pencere o projenin stüdyosu olur: Claude oturumları (tmux ile kalıcı),
`.claude/skills` skill'leri, zamanlanmış çalışmalar (launchd), servisler ve terminaller.

Kullanıcıya görünen tüm metin **Türkçe**dir; kod ve yorumlar da Türkçe yazılır.

## Komutlar

```bash
swift build      # hızlı derleme kontrolü
./build.sh       # release + "Claude Studio.app" paketi
./install.sh     # build + /Applications'a kur + aç
```

## Klasör Yapısı

```
Sources/ClaudeStudio/
├── main.swift             # giriş noktası (NSApplication; WindowGroup KULLANILMAZ)
├── ClaudeStudioApp.swift  # AppDelegate + ana menü
├── Theme.swift            # tek tasarım kaynağı: renk, tipografi, ortak bileşenler
├── Models/Models.swift    # Project, StudioTab, ClaudeSession, Skill, Schedule, Service, SkillRun
├── Core/
│   ├── Paths.swift        # ~/Library/.../Claude Studio  +  <proje>/.cs
│   ├── Shell.swift        # PATH anlık görüntüsü, süreç çalıştırma, port kontrolü
│   ├── Tmux.swift         # oturum kalıcılığı
│   ├── TerminalEngine.swift # SwiftTerm görünüm önbelleği, spawn, servis durumları, dikkat izleme
│   ├── ProjectConfig.swift  # .cs/config.json + launchd eşitlemesi
│   ├── Skills.swift       # .claude/skills tarayıcı + frontmatter + klasör izleyici
│   ├── Runs.swift         # çalışma raporları (durum = raporun kendisi)
│   ├── Scheduler.swift    # runner script + launchd plist
│   ├── HookBridge.swift   # Claude Code hook'ları → oturum durumu
│   ├── Settings.swift     # kullanıcı tercihleri (ses, bildirim, terminal)
│   ├── Recents.swift      # son projeler + klasör seçici
│   └── StudioModel.swift  # bir pencerenin tüm durumu
└── Views/                 # Windows, RootView, WelcomeView, StudioView, Sidebar, Detail,
                           # Sheets, SettingsWindow, Markdown, TerminalHost
```

## Kritik Kurallar

- **Pencereler**: `WindowGroup` KULLANMA. AppKit `WindowManager` pencere sayısını ve kimliğini
  belirlenimci tutar; SwiftUI'nin örtük pencere açması klasörle açmada kopyalar üretiyordu.
- **tmux**: her zaman sabit `-S /tmp/claude-studio-<uid>.sock`; `-L` KULLANMA (GUI ile login shell
  farklı `TMUX_TMPDIR` görür). Config'de `mouse off` şart — açıksa metin seçimi bozulur.
- **`Project.shortID`**: `hashValue` KULLANMA — Swift onu süreç başına rastgele tohumlar, tmux
  oturumları ve launchd job'ları her açılışta öksüz kalırdı. FNV-1a kullanılıyor.
- **Spawn**: her zaman `/bin/zsh -l -i -c`; `-i` zorunlu (PATH `.zshrc`'de). Komutun başına
  `stty cols C rows R`. Ortama `Shell.userPath` enjekte edilir.
- **launchd**: runner script'e PATH GÖMÜLÜ yazılır; `#!/bin/zsh -l`'in `.zshrc` okumasına güvenme.
  Script'te `setopt NULL_GLOB` şart — ilk çalışmada `*.md` eşleşmezse zsh hata verir.
- **Çok satırlı girdi**: tmux içinde `/terminal-setup` çalışmaz. Shift+Enter → `\`+CR,
  Option+Enter → ESC+CR eşlemesi `TerminalEngine.installKeyMonitor` içinde yapılır.
- **Kaydırma**: tmux destekli terminallerde tekerlek olayı copy-mode'a çevrilir ve YUTULUR
  (`return nil`). Yutulmazsa SwiftTerm'in boş kaydırması ekranı titretir.
- **Oturum kimliği**: `SessionRecord` `.cs/config.json`'da yaşar; tmux ölse de kayıt kalır.
  Claude'un `session_id`'si hook'tan yakalanıp kaydedilir — "geri aç" `claude --resume` ile
  aynı konuşmayı sürdürür.
- **SwiftTerm**: terminal görünümleri `TerminalEngine`'e aittir; görünüm katmanı yalnız barındırır.
  Konteyneri yeniden mount ETME (kaydırma sıfırlanır). `softReset()` kullan, `reset()` değil
  (geçmişi siler). Yeniden boyutlandırmada 80 ms sönümleme.
- **Bildirim**: `osascript display notification` kullan; ad-hoc imzalı uygulamada
  `UNUserNotificationCenter` çalışmaz. `NSSound` referansı tutulmalı, yoksa ses çıkmaz.
- **Yazma**: JSON'lar atomik yazılır (`Paths.writeAtomically`). Çözümlenemeyen
  `~/.claude/settings.json`'a DOKUNMA.
- **Eşzamanlılık**: `Task.detached` içinde biriktirilen `var`, `MainActor.run`'a `let` kopya
  olarak geçirilir (Swift 6 dil kipinde hata).

## Tasarım

Sade ve yerel. Renkler macOS'un anlamsal renkleridir (açık/koyu görünüme kendiliğinden uyar);
yalnız vurgu (Claude turuncusu) ve durum renkleri sabittir. Süsleme yok: sistem yazı tipi,
terminalde SF Mono. Yeni renk/ölçü eklemek gerekirse yalnız `Theme.swift` düzenlenir.
