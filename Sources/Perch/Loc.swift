import Foundation

/// Tiny in-app localisation. Turkish source strings are the keys; `en` holds English.
/// A table (instead of .lproj bundles) lets the language switch live, without a relaunch.
enum Loc {
    enum Choice: String, CaseIterable { case system, tr, en }

    static let key = "language"
    private(set) static var lang: String = resolve()

    static var choice: Choice {
        Choice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    static func set(_ c: Choice) {
        UserDefaults.standard.set(c.rawValue, forKey: key)
        lang = resolve()
    }

    private static func resolve() -> String {
        switch choice {
        case .tr: return "tr"
        case .en: return "en"
        case .system:
            let preferred = Locale.preferredLanguages.first?.prefix(2) ?? "en"
            return preferred == "tr" ? "tr" : "en"
        }
    }

    static var locale: Locale { Locale(identifier: lang == "tr" ? "tr_TR" : "en_US") }

    static func t(_ s: String) -> String {
        lang == "tr" ? s : (en[s] ?? s)
    }
}

/// Localised string; extra arguments fill `%@` / `%d` placeholders.
func L(_ s: String, _ args: CVarArg...) -> String {
    let base = Loc.t(s)
    return args.isEmpty ? base : String(format: base, locale: Loc.locale, arguments: args)
}

extension Loc {
    static let en: [String: String] = [
        // General / menu
        "Perch": "Perch",
        "Ayarlar": "Settings", "Çık": "Quit", "Kapat": "Close", "Aç": "Open", "Açık": "On", "Kapalı": "Off",
        "Yok": "None", "Verildi": "Granted", "Ara": "Search", "Durdur": "Stop", "Kaydet": "Save",
        "Kopyala": "Copy", "Kopyalandı": "Copied", "Kaydedildi": "Saved", "Farklı kaydet…": "Save As…",
        "Tümünü kapat": "Close all", "Yükleniyor…": "Loading…", "şimdi": "now",
        "Perch'ü Gizle": "Hide Perch", "Pencereyi Kapat": "Close Window", "Perch'ten Tamamen Çık": "Quit Perch Completely",
        "Düzen": "Edit", "Geri Al": "Undo", "Yinele": "Redo", "Kes": "Cut", "Yapıştır": "Paste",
        "Tümünü Seç": "Select All", "Pencere": "Window", "Küçült": "Minimize",
        "%dg %dsa": "%dd %dh", "%dsa %ddk": "%dh %dm", "%ddk": "%dm", "%dsn": "%ds",

        // Tabs
        "Temizlik": "Cleanup", "Büyük Dosyalar": "Large Files", "Uygulama Kaldır": "Uninstall Apps", "Etkinlik": "Activity",

        // Menu bar popover
        "Uyanık kal": "Stay awake", "Süresiz açık": "On indefinitely", "%@ kaldı": "%@ left",
        "∞": "∞", "15dk": "15m", "1sa": "1h", "2sa": "2h", "4sa": "4h", "8sa": "8h",
        "Kapak kapalıyken çalış": "Run with lid closed",
        "Uyku tamamen kapalı – çantaya koyarken dikkat": "Sleep fully disabled – careful in a bag",
        "Kapak kapanınca uyumaz": "Won't sleep when the lid closes",
        "Limitler": "Limits", "Sıfırlanma: %@": "Resets %@",
        "Alan": "Area", "Ekran": "Screen",
        "Mac'i en çok yoran uygulamalar": "Apps working your Mac hardest",
        "Gereksiz dosyaları temizle": "Clean up junk files",
        "Büyük dosya ve klasörler": "Large files and folders",
        "Uygulama ve verilerini kaldır": "Remove apps and their data",
        "İzin verilmedi": "Permission denied",
        "%@ ayarı geri değiştiriyor – onun kapak modunu kapat": "%@ keeps reverting it – turn off its lid mode",
        "Ayar uygulanmadı, başka bir uygulama değiştiriyor olabilir": "Not applied – another app may be changing it",

        // Usage
        "Oturum (5 sa)": "Session (5h)", "Haftalık": "Weekly", "Haftalık · Opus": "Weekly · Opus",
        "Haftalık · Sonnet": "Weekly · Sonnet", "Aylık": "Monthly", "Limit": "Limit",
        "%d günlük": "%d-day", "%d saatlik": "%d-hour", "Limit bilgisi yok": "No limit data",
        "Claude Code girişi bulunamadı": "No Claude Code login found",
        "Codex girişi bulunamadı (~/.codex/auth.json)": "No Codex login found (~/.codex/auth.json)",
        "Oturum süresi dolmuş – terminalde `claude` çalıştır": "Session expired – run `claude` in a terminal",
        "Oturum süresi dolmuş – terminalde `codex` çalıştır": "Session expired – run `codex` in a terminal",
        "Alınamadı (%d)": "Couldn't fetch (%d)",

        // Screenshot shelf
        "Sürükle-bırak · çift tıkla aç": "Drag & drop · double-click to open",

        // Cleanup
        "Silinmesi güvenli önbellek, günlük ve geçici dosyalar": "Caches, logs and temporary files that are safe to delete",
        "Yeniden tara": "Rescan", "Boş": "Empty", "Kalıcı sil": "Delete permanently",
        "Kalıcı olarak sil": "Delete permanently", "Çöp Kutusu'na taşı": "Move to Trash",
        "Temizle · %@": "Clean · %@", "Temizleniyor…": "Cleaning…",
        "Seçili %d öğe temizlensin mi?": "Clean %d selected items?",
        "Toplam %@. Önbellekler uygulamalar tarafından yeniden oluşturulur.": "%@ in total. Apps recreate their caches as needed.",
        "%@ temizlendi.": "%@ freed.", "%@ temizlendi (Çöp Kutusu'na taşındı).": "%@ freed (moved to Trash).",
        "Temizlendi; %d öğe kullanımda ya da korumalı olduğu için atlandı.": "Done; %d items were skipped because they're in use or protected.",
        "Finder'da göster": "Show in Finder",
        "Uygulama önbellekleri": "App caches",
        "~/Library/Caches – uygulamalar gerektiğinde yeniden oluşturur": "~/Library/Caches – apps rebuild these when needed",
        "Günlükler ve çökme raporları": "Logs and crash reports", "~/Library/Logs": "~/Library/Logs",
        "Xcode artıkları": "Xcode leftovers",
        "DerivedData, Previews, eski cihaz destek dosyaları": "DerivedData, Previews, old device support files",
        "Geliştirici paket önbellekleri": "Developer package caches",
        "npm, pnpm, yarn, bun, gradle, pip, cargo, CocoaPods…": "npm, pnpm, yarn, bun, gradle, pip, cargo, CocoaPods…",
        "İndirilen yükleyiciler": "Downloaded installers",
        "~/Downloads içindeki .dmg, .pkg, .xip dosyaları": ".dmg, .pkg and .xip files in ~/Downloads",
        "Mail ek indirmeleri": "Mail attachment downloads",
        "Mail'in açtığın eklerin kopyaları": "Copies of attachments you opened in Mail",
        "Çöp Kutusu": "Trash", "Kalıcı olarak silinir": "Deleted permanently",
        "Fotoğraflar, Mail ve uygulama kapsayıcıları gibi korumalı klasörler atlanıyor. Hepsini görmek için Perch'e Tam Disk Erişimi ver, sonra yeniden tara.":
            "Protected folders like Photos, Mail and app containers are skipped. Give Perch Full Disk Access to include them, then rescan.",
        "Ayarları aç": "Open Settings",

        // Disk usage
        "Büyük dosyalar": "Large files", "Klasörler": "Folders",
        "Başka bir klasör tara": "Scan another folder",
        "Taranıyor… %@ dosya · %@": "Scanning… %@ files · %@",
        "100 MB üzerinde dosya yok": "No files over 100 MB",
        "Çift tıkla: klasöre gir · sağ tık: Finder'da göster": "Double-click: open folder · right-click: show in Finder",
        "≥ 100 MB dosyalar, büyükten küçüğe": "Files ≥ 100 MB, largest first",
        "Yolu kopyala": "Copy path",
        "%d öğe Çöp Kutusu'na taşındı.": "Moved %d items to the Trash.",
        "%d öğe taşınamadı (izin yok).": "%d items couldn't be moved (no permission).",
        "%d öğe Çöp Kutusu'na taşınsın mı?": "Move %d items to the Trash?",

        // Uninstaller
        "Ad": "Name", "Boyut": "Size", "Dosyalar aranıyor…": "Looking for files…",
        "Kaldır": "Remove", "Kaldır · %@": "Remove · %@", "Kaldırılıyor…": "Removing…",
        "Kaldırmak istediğin uygulamayı seç": "Pick an app to uninstall",
        "Uygulama açık – kaldırırken kapatılacak": "App is running – it will be quit first",
        "%@ için %d öğe Çöp Kutusu'na taşınsın mı?": "Move %2$d items of %1$@ to the Trash?",
        "Çöp Kutusu'nu boşaltana kadar geri alabilirsin.": "You can undo this until you empty the Trash.",
        "%@: %d öğe Çöp Kutusu'na taşındı.": "%@: moved %d items to the Trash.",
        "%d öğe taşınamadı.": "%d items couldn't be moved.",
        "Uygulama": "Application", "Uygulama Desteği": "Application Support", "Önbellek": "Caches",
        "Tercihler": "Preferences", "Kapsayıcılar": "Containers", "Grup Kapsayıcıları": "Group Containers",
        "Kayıtlı Durum": "Saved State", "Günlükler": "Logs", "Web Verisi": "Web Data", "Çerezler": "Cookies",
        "Başlangıç Öğeleri": "Launch Agents", "Betikler": "Scripts", "Eklentiler": "Plug-ins", "Servisler": "Services",
        "Sistem · Uygulama Desteği": "System · Application Support", "Sistem · Önbellek": "System · Caches",
        "Sistem · Tercihler": "System · Preferences", "Sistem · Başlangıç Öğeleri": "System · Launch Agents",
        "Sistem · Arka Plan Servisleri": "System · Launch Daemons", "Sistem · Yardımcı Araçlar": "System · Helper Tools",
        "Sistem · Günlükler": "System · Logs", "Sistem · Kurulum Kayıtları": "System · Install Receipts",
        "Perch bazı korumalı dosyaları Çöp Kutusu'na taşımak istiyor.": "Perch wants to move some protected files to the Trash.",

        // Activity
        "Mac'i şu an en çok ne yoruyor?": "What's working your Mac hardest right now?",
        "İşlemci": "CPU", "Bellek": "Memory", "Mac'in tamamına göre": "Share of the whole Mac",
        "Toplam %@": "%@ total", "%@ · en çok kullananlar": "%@ · top users", "%d işlem": "%d processes",
        "Sistem ve arka plan": "System & background",
        "Sistem ve arka plan işlemlerini tek tek göster": "Show system & background processes individually",
        "Uygulamadan çık": "Quit app", "Zorla kapat": "Force quit", "Zorla kapat…": "Force quit…",
        "%@ yanıt vermiyor mu? Zorla kapatılsın mı?": "Is %@ not responding? Force quit it?",
        "Kaydedilmemiş değişiklikler kaybolur.": "Unsaved changes will be lost.",
        "Bellek dolmak üzere": "Memory is almost full",
        "En çok %@ kullanıyor (%@). Kapatırsan Mac hemen rahatlar.": "%@ uses the most (%@). Quitting it will free things up right away.",
        "Bellek zorlanıyor": "Memory is under pressure",
        "Mac yavaşlayabilir. En büyük pay %@ uygulamasında (%@).": "Your Mac may slow down. %@ has the biggest share (%@).",
        "İşlemci çok yoğun": "CPU is very busy",
        "%@ işlemcinin %@ kadarını kullanıyor. Pil ve ısınma için kapatmayı düşünebilirsin.": "%@ is using %@ of the CPU. Consider quitting it to save battery and heat.",
        "Mac biraz meşgul": "Your Mac is a bit busy",
        "Şu an en çok %@ çalışıyor (%@). Endişelenecek bir durum yok.": "%@ is the busiest right now (%@). Nothing to worry about.",
        "Her şey yolunda": "All good",
        "Mac rahat çalışıyor. İşlemci %@, bellek %@ / %@.": "Your Mac is running comfortably. CPU %@, memory %@ / %@.",

        // Dusk redesign
        "temizlenebilir alan bulundu": "of space you can free up",
        "Taranıyor…": "Scanning…",
        "%d öğe seçildi": "%d selected",
        "Seçimi temizle": "Clear selection",
        "Uygulamayı ve geride bıraktığı her şeyi sil": "Remove an app and everything it leaves behind",
        "Canlı": "Live",
        "en çok kullananlar": "top users",
        "Sen onaylamadan hiçbir şey silinmez": "Nothing is deleted without your OK",
        "Mac'ini temizleyelim": "Let's tidy up your Mac",
        "Uygulamaların yeniden oluşturabildiği önbellekleri, eski günlükleri ve artık dosyaları bulurum. Neyin silineceğine sen karar verirsin.":
            "I'll find caches apps can rebuild, old logs and leftover files. You decide what gets deleted.",
        "Taramayı başlat": "Start scan",
        "Diskinde en çok yer kaplayan klasör ve dosyalar": "The folders and files taking up the most space",
        "Yer kaplayanları bul": "Find the space hogs",
        "Seçtiğin klasörü baştan sona tarar, klasörleri boyuta göre sıralar ve 100 MB üzerindeki dosyaları listelerim.":
            "I'll scan the folder you pick, rank its folders by size and list every file over 100 MB.",
        "Klasör boyutları": "Folder sizes", "Ana klasör": "Home folder", "≥ 100 MB dosyalar": "Files ≥ 100 MB",
        "Başka bir klasör seç…": "Choose another folder…",
        // Settings
        "Genel": "General", "Dil": "Language", "Sistem": "System",
        "Girişte otomatik başlat": "Launch at login",
        "Tam Disk Erişimi": "Full Disk Access", "Sistem Ayarları'nı aç": "Open System Settings",
        "Menü çubuğunda Claude oturum yüzdesini göster": "Show Claude session % in the menu bar",
        "Uyanık kalma": "Stay awake", "Ekranı da açık tut": "Keep the display on too",
        "Kapak kapalı modu": "Lid-closed mode", "Şifresiz": "Passwordless", "Şifresiz kullanımı kur…": "Set up passwordless use…",
        "Kapak modu `pmset disablesleep` kullanır ve root ister. Şifresiz kurulum, yalnızca bu iki pmset komutuna izin veren bir sudoers kuralı ekler (/etc/sudoers.d/perch). Perch kapanırken ayar geri alınır.":
            "Lid mode uses `pmset disablesleep` and needs root. Passwordless setup adds a sudoers rule that allows only these two pmset commands (/etc/sudoers.d/perch). The setting is restored when Perch quits.",
        "Perch kapak modu için bir kerelik izin istiyor. Sonraki açıp kapatmalarda şifre sorulmayacak.":
            "Perch needs one-time permission for lid mode. You won't be asked for a password again.",
        "Perch, kapak modu için şifresiz pmset izni kurmak istiyor.": "Perch wants to set up passwordless pmset access for lid mode.",
        "Perch şifresiz pmset iznini kaldırmak istiyor.": "Perch wants to remove passwordless pmset access.",
        "Ekran görüntüsü": "Screenshots", "Alan / pencere": "Area / window", "Tam ekran": "Full screen",
        "Alan modunda Boşluk tuşu pencere seçimine geçer.": "In area mode, press Space to pick a window.",
        "macOS'in kendi ⇧⌘3 / ⇧⌘4 kısayolları açık ve Perch'ünkünü eziyor. Klavye › Kısayollar › Ekran Görüntüleri'nden kapat.":
            "macOS's own ⇧⌘3 / ⇧⌘4 shortcuts are on and override Perch's. Turn them off in Keyboard › Shortcuts › Screenshots.",
        "Alındığında panoya kopyala": "Copy to clipboard after capture",
        "Kaydetme klasörü": "Save folder", "Değiştir…": "Change…",
        "Yığından otomatik kaldır": "Auto-remove from stack", "Asla": "Never",
        "30 saniye": "30 seconds", "1 dakika": "1 minute", "5 dakika": "5 minutes",
        "Ekran kaydı izni": "Screen Recording permission", "Kısayola bas…": "Press shortcut…",
    ]
}
