import Foundation
import SwiftUI

// MARK: - App UI language (persisted with @AppStorage key `appUILanguage`)

enum AppUILanguage: String, CaseIterable, Identifiable, Hashable {
    case en = "en"
    case zhHans = "zh-Hans"
    case es = "es"

    var id: String { rawValue }

    /// User-facing name in the language itself (no flags).
    var displayName: String {
        switch self {
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .es: return "Español"
        }
    }

    static let storageKey = "appUILanguage"

    var locale: Locale {
        switch self {
        case .en: return Locale(identifier: "en_US")
        case .zhHans: return Locale(identifier: "zh_CN")
        case .es: return Locale(identifier: "es_ES")
        }
    }

    var uiLocaleIdentifier: String {
        locale.identifier.replacingOccurrences(of: "-", with: "_")
    }

    init(storageRaw: String) {
        self = AppUILanguage(rawValue: storageRaw) ?? .en
    }

    static func defaultForDevice() -> AppUILanguage {
        let primary = Locale.preferredLanguages.first?.lowercased() ?? ""
        if primary.hasPrefix("zh-hans") || primary.hasPrefix("zh-cn") { return .zhHans }
        if primary.hasPrefix("es") { return .es }
        return .en
    }

    static func migrateLegacyUserDefaultsIfNeeded() {
        guard UserDefaults.standard.object(forKey: storageKey) == nil else { return }
        if let old = UserDefaults.standard.string(forKey: "appLanguage") {
            switch old {
            case "chineseSimplified": UserDefaults.standard.set(zhHans.rawValue, forKey: storageKey)
            case "english": UserDefaults.standard.set(en.rawValue, forKey: storageKey)
            default: break
            }
        }
    }

    var strings: AppStrings {
        switch self {
        case .en: return .english
        case .zhHans: return .chineseSimplified
        case .es: return .spanish
        }
    }

    var speechMessages: SpeechServiceMessages {
        switch self {
        case .en: return .english
        case .zhHans: return .chineseSimplified
        case .es: return .spanish
        }
    }
}

// MARK: - Environment

private enum AppUILanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppUILanguage = .en
}

extension EnvironmentValues {
    var appUILanguage: AppUILanguage {
        get { self[AppUILanguageEnvironmentKey.self] }
        set { self[AppUILanguageEnvironmentKey.self] = newValue }
    }
}

// MARK: - UI strings

struct AppStrings {
    let tagline: String
    let permissionStatus: String
    let tasks: String
    let today: String
    let overdue: String
    let upcoming: String
    let doneColumn: String
    let nothingHereYet: String
    let permissionsDeniedPrefix: String
    let openPermissionHint: String
    let openCommandChat: String
    let newTaskA11y: String
    let homeTab: String
    let calendarTab: String
    let calendarTitle: String
    let previousMonth: String
    let nextMonth: String
    let noTasksThisDay: String
    let commandTitle: String
    let dismissDone: String
    let titlePlaceholder: String
    let notesPlaceholder: String
    let date: String
    let time: String
    let removeDate: String
    let specificTime: String
    let none: String
    let todaySummary: String
    let tomorrowSummary: String
    let anytime: String
    let newTask: String
    let cancel: String
    let add: String
    let taskSection: String
    let scheduleSection: String
    let scheduledToggle: String
    let datePickerLabel: String
    let timePickerLabel: String
    let scheduleHint: String
    let completed: String
    let deleteTask: String
    let markComplete: String
    let markIncomplete: String
    let editTaskDetails: String
    let permissionsNavigationTitle: String
    let permissionsIntro: String
    let permissionsStatusHeader: String
    let lastMessageHeader: String
    let settings: String
    let requestAccess: String
    let permissionMicrophone: String
    let permissionSpeech: String
    let permissionNotifications: String
    let permissionCalendar: String
    let permissionMicExplanation: String
    let permissionSpeechExplanation: String
    let permissionNotificationsExplanation: String
    let permissionCalendarExplanation: String
    let statusNotAsked: String
    let statusAllowed: String
    let statusDenied: String
    let statusRestricted: String
    let statusProvisional: String
    let statusUnknown: String
    let voiceTapToSpeak: String
    let voiceListening: String
    let voiceProcessing: String
    let voiceReady: String
    let voiceError: String
    let voiceStartListening: String
    let voiceStopListening: String
    let chatEmptyTranscript: String
    /// User was offline when the transcription call was made.
    let chatErrorOffline: String
    /// Audio file was empty or too short to contain speech.
    let chatErrorNothingRecorded: String
    /// Cloud service returned an HTTP error (4xx / 5xx).
    let chatErrorServiceUnavailable: String
    /// Decoding or any other unexpected internal failure.
    let chatErrorSomethingWentWrong: String
    /// API key is missing / service not configured — never say "API key" to the user.
    let chatErrorServiceNotAvailable: String
    let chatUnknownSchedule: String
    let chatTryRemind: String
    let chatReminderMinutes: String
    let chatReminderMinutesPlural: String
    let chatReminderHours: String
    let chatReminderHoursPlural: String
    let chatReminderAt: String
    let chatReminderAbout: String
    let chatEventAt: String
    let chatEventCalendar: String
    /// Second sentence when notes exist; single "%@" for the note text (title language preserved).
    let chatAlsoNoted: String
    let chatYourTask: String
    let taskCountOne: String
    let taskCountMany: String
    let selected: String
    let permissionMicDeniedAfterRequest: String
    let permissionSpeechDeniedAfterRequest: String
    let permissionNotificationsDenied: String
    let permissionNotificationsErrorPrefix: String
    let permissionCalendarDenied: String
    let permissionCalendarErrorPrefix: String
    let chatConflictWarning: String
    let chatConflictAddAnyway: String
    let chatConflictCancel: String
    let chatConflictCanceled: String
    let chatEditNoTaskFound: String
    let chatEditAmbiguousTask: String
    let chatDisambiguateSelect: String
    let chatDeletePrompt: String
    let chatDeleteConfirm: String
    let chatDeleteKeep: String
    let chatDeleteSuccess: String
    let chatDeleteCanceled: String
    let chatRescheduleSuccess: String
    let chatAppendSuccess: String
    let chatTextInputPlaceholder: String
    let reminderLabel: String
    let reminderDefaultLabel: String
    let appLanguage: String
    let settingsNavigationTitle: String
    let settingsPermissionsSection: String
    let settingsPermissionNotificationsTitle: String
    let settingsPermissionMicrophoneTitle: String
    let settingsPermissionSpeechTitle: String
    let settingsPermissionEnabled: String
    let settingsPermissionDisabled: String
    let settingsPermissionNotificationsFooter: String
    let settingsPermissionMicrophoneFooter: String
    let settingsPermissionSpeechFooter: String

    static let english = AppStrings(
        tagline: "Speak → Understand → Schedule → Remind",
        permissionStatus: "Permission status",
        tasks: "Tasks",
        today: "Today",
        overdue: "Overdue",
        upcoming: "Upcoming",
        doneColumn: "Done",
        nothingHereYet: "Nothing here yet",
        permissionsDeniedPrefix: "Some permissions are denied:",
        openPermissionHint: "Open Permission status to request access or fix in Settings.",
        openCommandChat: "Open command chat",
        newTaskA11y: "New task",
        homeTab: "Home",
        calendarTab: "Calendar",
        calendarTitle: "Calendar",
        previousMonth: "Previous month",
        nextMonth: "Next month",
        noTasksThisDay: "No tasks on this day",
        commandTitle: "Command",
        dismissDone: "Done",
        titlePlaceholder: "Title",
        notesPlaceholder: "Notes",
        date: "Date",
        time: "Time",
        removeDate: "Remove date",
        specificTime: "Specific time",
        none: "None",
        todaySummary: "Today",
        tomorrowSummary: "Tomorrow",
        anytime: "Anytime",
        newTask: "New Task",
        cancel: "Cancel",
        add: "Add",
        taskSection: "Task",
        scheduleSection: "Schedule",
        scheduledToggle: "Scheduled",
        datePickerLabel: "Date",
        timePickerLabel: "Time",
        scheduleHint: "Leave “Specific time” off to treat the task as Anytime on that day.",
        completed: "Completed",
        deleteTask: "Delete Task",
        markComplete: "Mark complete",
        markIncomplete: "Mark incomplete",
        editTaskDetails: "Edit task details",
        permissionsNavigationTitle: "Permissions",
        permissionsIntro: "ChatTask needs these permissions to hear you, understand speech, remind you, and add calendar events. Denied items can be changed in Settings.",
        permissionsStatusHeader: "Status",
        lastMessageHeader: "Last message",
        settings: "Settings",
        requestAccess: "Request access",
        permissionMicrophone: "Microphone",
        permissionSpeech: "Speech Recognition",
        permissionNotifications: "Notifications",
        permissionCalendar: "Calendar",
        permissionMicExplanation: "Needed to hear your voice commands.",
        permissionSpeechExplanation: "Needed to turn speech into text.",
        permissionNotificationsExplanation: "Needed to remind you at the right time.",
        permissionCalendarExplanation: "Needed to add events to your calendar.",
        statusNotAsked: "Not asked",
        statusAllowed: "Allowed",
        statusDenied: "Denied",
        statusRestricted: "Restricted",
        statusProvisional: "Provisional",
        statusUnknown: "Unknown",
        voiceTapToSpeak: "Tap the microphone to speak.",
        voiceListening: "Listening… I’ll stop when you finish speaking. Tap to stop anytime.",
        voiceProcessing: "Processing…",
        voiceReady: "Ready for your next command.",
        voiceError: "Something went wrong — try again.",
        voiceStartListening: "Start listening",
        voiceStopListening: "Stop listening",
        chatEmptyTranscript: "I didn’t catch that. Try speaking a bit longer.",
        chatErrorOffline: "You're offline. Please check your internet connection.",
        chatErrorNothingRecorded: "Couldn’t hear anything. Please try again.",
        chatErrorServiceUnavailable: "Service is temporarily unavailable. Please try again.",
        chatErrorSomethingWentWrong: "Something went wrong. Please try again.",
        chatErrorServiceNotAvailable: "Service is not available right now.",
        chatUnknownSchedule: """
            I saved %@, but I couldn’t confidently figure out a date or time from what you said.

            Open the task from Home or Calendar, tap it, and set the schedule (or leave it as Anytime) in the editor.
            """,
        chatTryRemind: "I’m not sure how to schedule that yet. Try “remind me…” or “today at 3 PM…”.",
        chatReminderMinutes: "Got it — I’ll remind you in %1$d minute to %2$@.",
        chatReminderMinutesPlural: "Got it — I’ll remind you in %1$d minutes to %2$@.",
        chatReminderHours: "Got it — I’ll remind you in %1$d hour to %2$@.",
        chatReminderHoursPlural: "Got it — I’ll remind you in %1$d hours to %2$@.",
        chatReminderAt: "Got it — I’ll remind you at %1$@ to %2$@.",
        chatReminderAbout: "Got it — I’ll remind you to %@.",
        chatEventAt: "Got it — I’ve noted %1$@ for %2$@.",
        chatEventCalendar: "Got it — I’ve put %@ on your calendar.",
        chatAlsoNoted: "Also noted: %@.",
        chatYourTask: "your task",
        taskCountOne: "1 task",
        taskCountMany: "%d tasks",
        selected: "selected",
        permissionMicDeniedAfterRequest: "Microphone access was denied. You can enable it in Settings.",
        permissionSpeechDeniedAfterRequest: "Speech recognition was denied. You can enable it in Settings.",
        permissionNotificationsDenied: "Notifications were not allowed. You can enable them in Settings.",
        permissionNotificationsErrorPrefix: "Could not request notifications:",
        permissionCalendarDenied: "Calendar access was denied. You can enable it in Settings.",
        permissionCalendarErrorPrefix: "Calendar error:",
        chatConflictWarning: "Heads up — you already have \"%@\" at %@. Add \"%@\" at the same time anyway?",
        chatConflictAddAnyway: "Add anyway",
        chatConflictCancel: "Don't add",
        chatConflictCanceled: "Got it, task not saved.",
        chatEditNoTaskFound: "I couldn't find a task at that time. Try saying the time more precisely.",
        chatEditAmbiguousTask: "I found more than one task around that time. Please be more specific.",
        chatDisambiguateSelect: "Found %d tasks at that time — which one did you mean?",
        chatDeletePrompt: "Delete \"%@\"?",
        chatDeleteConfirm: "Delete",
        chatDeleteKeep: "Keep it",
        chatDeleteSuccess: "Deleted \"%@\".",
        chatDeleteCanceled: "OK, kept it.",
        chatRescheduleSuccess: "Done — moved \"%@\" to %@.",
        chatAppendSuccess: "Added note to \"%@\".",
        chatTextInputPlaceholder: "Type or say a task\u{2026}",
        reminderLabel: "Reminder",
        reminderDefaultLabel: "Default Reminder",
        appLanguage: "App Language",
        settingsNavigationTitle: "Settings",
        settingsPermissionsSection: "Permissions",
        settingsPermissionNotificationsTitle: "Notifications",
        settingsPermissionMicrophoneTitle: "Microphone",
        settingsPermissionSpeechTitle: "Speech Recognition",
        settingsPermissionEnabled: "Enabled",
        settingsPermissionDisabled: "Disabled",
        settingsPermissionNotificationsFooter: "Required for reminders to alert you on time.",
        settingsPermissionMicrophoneFooter: "Used for voice commands.",
        settingsPermissionSpeechFooter: "Used to convert your voice into tasks."
    )

    static let chineseSimplified = AppStrings(
        tagline: "说话 → 理解 → 安排 → 提醒",
        permissionStatus: "权限状态",
        tasks: "任务",
        today: "今天",
        overdue: "逾期",
        upcoming: "未来",
        doneColumn: "已完成",
        nothingHereYet: "暂无内容",
        permissionsDeniedPrefix: "部分权限被拒绝：",
        openPermissionHint: "打开「权限状态」以请求权限或在设置中修复。",
        openCommandChat: "打开语音指令",
        newTaskA11y: "新任务",
        homeTab: "首页",
        calendarTab: "日历",
        calendarTitle: "日历",
        previousMonth: "上个月",
        nextMonth: "下个月",
        noTasksThisDay: "当天没有任务",
        commandTitle: "指令",
        dismissDone: "完成",
        titlePlaceholder: "标题",
        notesPlaceholder: "备注",
        date: "日期",
        time: "时间",
        removeDate: "移除日期",
        specificTime: "具体时间",
        none: "无",
        todaySummary: "今天",
        tomorrowSummary: "明天",
        anytime: "随时",
        newTask: "新任务",
        cancel: "取消",
        add: "添加",
        taskSection: "任务",
        scheduleSection: "日程",
        scheduledToggle: "已计划",
        datePickerLabel: "日期",
        timePickerLabel: "时间",
        scheduleHint: "关闭「具体时间」则该任务在当天为随时。",
        completed: "已完成",
        deleteTask: "删除任务",
        markComplete: "标记为完成",
        markIncomplete: "标记为未完成",
        editTaskDetails: "编辑任务详情",
        permissionsNavigationTitle: "权限",
        permissionsIntro: "ChatTask 需要这些权限以听取语音、识别文字、发送提醒并添加日历事件。可在设置中更改已拒绝的项。",
        permissionsStatusHeader: "状态",
        lastMessageHeader: "最近提示",
        settings: "设置",
        requestAccess: "请求授权",
        permissionMicrophone: "麦克风",
        permissionSpeech: "语音识别",
        permissionNotifications: "通知",
        permissionCalendar: "日历",
        permissionMicExplanation: "用于听取语音指令。",
        permissionSpeechExplanation: "用于将语音转为文字。",
        permissionNotificationsExplanation: "用于在合适时间提醒您。",
        permissionCalendarExplanation: "用于向日历添加事件。",
        statusNotAsked: "未询问",
        statusAllowed: "已允许",
        statusDenied: "已拒绝",
        statusRestricted: "受限制",
        statusProvisional: "临时",
        statusUnknown: "未知",
        voiceTapToSpeak: "点击麦克风开始说话。",
        voiceListening: "正在聆听… 说完后自动停止，也可随时点击停止。",
        voiceProcessing: "处理中…",
        voiceReady: "可以说下一条指令了。",
        voiceError: "出错了，请重试。",
        voiceStartListening: "开始聆听",
        voiceStopListening: "停止聆听",
        chatEmptyTranscript: "没听清，请再说长一点。",
        chatErrorOffline: "您已离线，请检查网络连接。",
        chatErrorNothingRecorded: "没有听到声音，请重试。",
        chatErrorServiceUnavailable: "服务暂时不可用，请稍后重试。",
        chatErrorSomethingWentWrong: "出错了，请重试。",
        chatErrorServiceNotAvailable: "服务目前不可用。",
        chatUnknownSchedule: """
            已保存 %@，但无法从您的话里确定日期或时间。

            请在首页或日历中打开该任务，点进去在编辑器里设置日程（或保留为随时）。
            """,
        chatTryRemind: "还不太会安排这类说法。试试「提醒我…」或「今天下午 3 点…」。",
        chatReminderMinutes: "好的——%1$d 分钟后提醒你%2$@。",
        chatReminderMinutesPlural: "好的——%1$d 分钟后提醒你%2$@。",
        chatReminderHours: "好的——%1$d 小时后提醒你%2$@。",
        chatReminderHoursPlural: "好的——%1$d 小时后提醒你%2$@。",
        chatReminderAt: "好的——我会在 %1$@ 提醒你%2$@。",
        chatReminderAbout: "好的——我会提醒你%@。",
        chatEventAt: "好的——已记下 %1$@，时间 %2$@。",
        chatEventCalendar: "好的——已把 %@ 记在日历上。",
        chatAlsoNoted: "另外：%@。",
        chatYourTask: "该任务",
        taskCountOne: "1 个任务",
        taskCountMany: "%d 个任务",
        selected: "已选中",
        permissionMicDeniedAfterRequest: "麦克风权限被拒绝。可在设置中开启。",
        permissionSpeechDeniedAfterRequest: "语音识别权限被拒绝。可在设置中开启。",
        permissionNotificationsDenied: "未允许通知。可在设置中开启。",
        permissionNotificationsErrorPrefix: "无法请求通知：",
        permissionCalendarDenied: "日历权限被拒绝。可在设置中开启。",
        permissionCalendarErrorPrefix: "日历错误：",
        chatConflictWarning: "注意：你已有「%@」安排在 %@。仍要添加「%@」吗？",
        chatConflictAddAnyway: "仍要添加",
        chatConflictCancel: "不添加",
        chatConflictCanceled: "好的，已取消。",
        chatEditNoTaskFound: "找不到该时间的任务，请说得更精确一些。",
        chatEditAmbiguousTask: "该时间附近有多个任务，请说得更具体一些。",
        chatDisambiguateSelect: "该时间附近有 %d 个任务，是哪一个？",
        chatDeletePrompt: "删除「%@」？",
        chatDeleteConfirm: "删除",
        chatDeleteKeep: "保留",
        chatDeleteSuccess: "已删除「%@」。",
        chatDeleteCanceled: "好的，已保留。",
        chatRescheduleSuccess: "已完成——将「%@」改到 %@。",
        chatAppendSuccess: "已为「%@」添加备注。",
        chatTextInputPlaceholder: "输入或说出任务\u{2026}",
        reminderLabel: "提醒",
        reminderDefaultLabel: "默认提醒时间",
        appLanguage: "应用语言",
        settingsNavigationTitle: "设置",
        settingsPermissionsSection: "权限",
        settingsPermissionNotificationsTitle: "通知",
        settingsPermissionMicrophoneTitle: "麦克风",
        settingsPermissionSpeechTitle: "语音识别",
        settingsPermissionEnabled: "已开启",
        settingsPermissionDisabled: "未开启",
        settingsPermissionNotificationsFooter: "用于在约定时间发送提醒。",
        settingsPermissionMicrophoneFooter: "用于语音指令。",
        settingsPermissionSpeechFooter: "用于将语音转为任务。"
    )

    static let spanish = AppStrings(
        tagline: "Habla → Entiende → Planifica → Recuerda",
        permissionStatus: "Estado de permisos",
        tasks: "Tareas",
        today: "Hoy",
        overdue: "Atrasadas",
        upcoming: "Próximas",
        doneColumn: "Hechas",
        nothingHereYet: "Nada por aquí",
        permissionsDeniedPrefix: "Algunos permisos están denegados:",
        openPermissionHint: "Abre Estado de permisos para solicitar acceso o cámbialo en Ajustes.",
        openCommandChat: "Abrir chat de comandos",
        newTaskA11y: "Nueva tarea",
        homeTab: "Inicio",
        calendarTab: "Calendario",
        calendarTitle: "Calendario",
        previousMonth: "Mes anterior",
        nextMonth: "Mes siguiente",
        noTasksThisDay: "No hay tareas este día",
        commandTitle: "Comando",
        dismissDone: "Listo",
        titlePlaceholder: "Título",
        notesPlaceholder: "Notas",
        date: "Fecha",
        time: "Hora",
        removeDate: "Quitar fecha",
        specificTime: "Hora concreta",
        none: "Ninguna",
        todaySummary: "Hoy",
        tomorrowSummary: "Mañana",
        anytime: "Cualquier hora",
        newTask: "Nueva tarea",
        cancel: "Cancelar",
        add: "Añadir",
        taskSection: "Tarea",
        scheduleSection: "Planificación",
        scheduledToggle: "Programada",
        datePickerLabel: "Fecha",
        timePickerLabel: "Hora",
        scheduleHint: "Desactiva «Hora concreta» para tratar la tarea como «Cualquier hora» ese día.",
        completed: "Completada",
        deleteTask: "Eliminar tarea",
        markComplete: "Marcar como completada",
        markIncomplete: "Marcar como pendiente",
        editTaskDetails: "Editar detalles de la tarea",
        permissionsNavigationTitle: "Permisos",
        permissionsIntro: "ChatTask necesita estos permisos para oírte, entender el habla, enviar recordatorios y añadir eventos al calendario. Los elementos denegados se pueden cambiar en Ajustes.",
        permissionsStatusHeader: "Estado",
        lastMessageHeader: "Último mensaje",
        settings: "Ajustes",
        requestAccess: "Solicitar acceso",
        permissionMicrophone: "Micrófono",
        permissionSpeech: "Reconocimiento de voz",
        permissionNotifications: "Notificaciones",
        permissionCalendar: "Calendario",
        permissionMicExplanation: "Necesario para oír tus comandos de voz.",
        permissionSpeechExplanation: "Necesario para convertir el habla en texto.",
        permissionNotificationsExplanation: "Necesario para recordarte a tiempo.",
        permissionCalendarExplanation: "Necesario para añadir eventos a tu calendario.",
        statusNotAsked: "Sin preguntar",
        statusAllowed: "Permitido",
        statusDenied: "Denegado",
        statusRestricted: "Restringido",
        statusProvisional: "Provisional",
        statusUnknown: "Desconocido",
        voiceTapToSpeak: "Toca el micrófono para hablar.",
        voiceListening: "Escuchando… pararé cuando termines de hablar. Toca para detener en cualquier momento.",
        voiceProcessing: "Procesando…",
        voiceReady: "Listo para tu siguiente comando.",
        voiceError: "Algo salió mal — inténtalo de nuevo.",
        voiceStartListening: "Empezar a escuchar",
        voiceStopListening: "Dejar de escuchar",
        chatEmptyTranscript: "No te he oído bien. Habla un poco más.",
        chatErrorOffline: "Estás sin conexión. Comprueba tu acceso a internet.",
        chatErrorNothingRecorded: "No pude escuchar nada. Por favor, inténtalo de nuevo.",
        chatErrorServiceUnavailable: "El servicio no está disponible en este momento. Inténtalo más tarde.",
        chatErrorSomethingWentWrong: "Algo salió mal. Por favor, inténtalo de nuevo.",
        chatErrorServiceNotAvailable: "El servicio no está disponible ahora mismo.",
        chatUnknownSchedule: """
            Guardé %@, pero no pude deducir con seguridad una fecha u hora de lo que dijiste.

            Abre la tarea desde Inicio o Calendario, tócala y configura la planificación en el editor (o déjala como «Cualquier hora»).
            """,
        chatTryRemind: "Aún no sé programar eso. Prueba «recuérdame…» o «hoy a las 15:00…».",
        chatReminderMinutes: "De acuerdo — te recordaré en %1$d minuto para %2$@.",
        chatReminderMinutesPlural: "De acuerdo — te recordaré en %1$d minutos para %2$@.",
        chatReminderHours: "De acuerdo — te recordaré en %1$d hora para %2$@.",
        chatReminderHoursPlural: "De acuerdo — te recordaré en %1$d horas para %2$@.",
        chatReminderAt: "De acuerdo — te recordaré a las %1$@ para %2$@.",
        chatReminderAbout: "De acuerdo — te recordaré para %@.",
        chatEventAt: "De acuerdo — anoté %1$@ para %2$@.",
        chatEventCalendar: "De acuerdo — puse %@ en tu calendario.",
        chatAlsoNoted: "También anoté: %@.",
        chatYourTask: "tu tarea",
        taskCountOne: "1 tarea",
        taskCountMany: "%d tareas",
        selected: "seleccionado",
        permissionMicDeniedAfterRequest: "Se denegó el micrófono. Puedes activarlo en Ajustes.",
        permissionSpeechDeniedAfterRequest: "Se denegó el reconocimiento de voz. Puedes activarlo en Ajustes.",
        permissionNotificationsDenied: "No se permitieron notificaciones. Puedes activarlas en Ajustes.",
        permissionNotificationsErrorPrefix: "No se pudieron solicitar notificaciones:",
        permissionCalendarDenied: "Se denegó el calendario. Puedes activarlo en Ajustes.",
        permissionCalendarErrorPrefix: "Error de calendario:",
        chatConflictWarning: "Aviso: ya tienes \"%@\" a las %@. ¿Añadir \"%@\" a la misma hora de todas formas?",
        chatConflictAddAnyway: "Añadir igual",
        chatConflictCancel: "No añadir",
        chatConflictCanceled: "Entendido, tarea no guardada.",
        chatEditNoTaskFound: "No encontré ninguna tarea a esa hora. Intenta decir la hora más exactamente.",
        chatEditAmbiguousTask: "Encontré varias tareas cerca de esa hora. Por favor, sé más específico.",
        chatDisambiguateSelect: "Encontré %d tareas a esa hora — ¿cuál de ellas?",
        chatDeletePrompt: "¿Eliminar \"%@\"?",
        chatDeleteConfirm: "Eliminar",
        chatDeleteKeep: "Conservar",
        chatDeleteSuccess: "Eliminado \"%@\".",
        chatDeleteCanceled: "De acuerdo, conservado.",
        chatRescheduleSuccess: "Listo — moví \"%@\" a %@.",
        chatAppendSuccess: "Nota añadida a \"%@\".",
        chatTextInputPlaceholder: "Escribe o di una tarea\u{2026}",
        reminderLabel: "Recordatorio",
        reminderDefaultLabel: "Recordatorio predeterminado",
        appLanguage: "Idioma",
        settingsNavigationTitle: "Ajustes",
        settingsPermissionsSection: "Permisos",
        settingsPermissionNotificationsTitle: "Notificaciones",
        settingsPermissionMicrophoneTitle: "Micrófono",
        settingsPermissionSpeechTitle: "Reconocimiento de voz",
        settingsPermissionEnabled: "Activado",
        settingsPermissionDisabled: "Desactivado",
        settingsPermissionNotificationsFooter: "Necesarias para que los recordatorios lleguen a tiempo.",
        settingsPermissionMicrophoneFooter: "Se usa para comandos de voz.",
        settingsPermissionSpeechFooter: "Convierte tu voz en tareas."
    )
}

extension PermissionKind {
    func localizedTitle(strings: AppStrings) -> String {
        switch self {
        case .microphone: return strings.permissionMicrophone
        case .speech: return strings.permissionSpeech
        case .notifications: return strings.permissionNotifications
        case .calendar: return strings.permissionCalendar
        }
    }

    func localizedExplanation(strings: AppStrings) -> String {
        switch self {
        case .microphone: return strings.permissionMicExplanation
        case .speech: return strings.permissionSpeechExplanation
        case .notifications: return strings.permissionNotificationsExplanation
        case .calendar: return strings.permissionCalendarExplanation
        }
    }
}

// MARK: - Speech recognizer user messages

struct SpeechServiceMessages: Equatable {
    let speechNotAvailable: String
    let micDeniedSettings: String
    let micDenied: String
    let micUnavailable: String
    let unsupportedLocale: String
    let localeUnavailable: String
    let micUseFailed: String
    let micInputUnavailable: String
    let audioStartFailed: String
    let nothingToStop: String
    let speechDeniedSettings: String
    let speechRestricted: String
    let speechNotDetermined: String
    let speechNotAllowed: String
    let noSpeechDetected: String
    let recognitionCanceled: String
    let recognitionFailedFormat: String
    let recognitionStopped: String
    let interrupted: String

    static let english = SpeechServiceMessages(
        speechNotAvailable: "Speech recognition is not available.",
        micDeniedSettings: "Microphone access was denied. Enable it in Settings → Privacy → Microphone.",
        micDenied: "Microphone access is denied. Enable it in Settings → Privacy → Microphone.",
        micUnavailable: "Microphone is not available.",
        unsupportedLocale: "Speech recognition isn’t supported for “%@”. Try another language.",
        localeUnavailable: "Speech recognition isn’t available for “%@” on this device right now. Try English, check your network, or try again later.",
        micUseFailed: "Could not use the microphone: %@",
        micInputUnavailable: "Microphone input isn’t available on this device.",
        audioStartFailed: "Could not start audio: %@",
        nothingToStop: "Nothing to stop — start listening first.",
        speechDeniedSettings: "Speech recognition is turned off. Enable it in Settings → Privacy → Speech Recognition.",
        speechRestricted: "Speech recognition is restricted on this device.",
        speechNotDetermined: "Speech recognition permission is required.",
        speechNotAllowed: "Speech recognition isn’t allowed.",
        noSpeechDetected: "No speech was detected. Try again and speak a bit closer to the microphone.",
        recognitionCanceled: "Recognition was canceled.",
        recognitionFailedFormat: "Speech recognition failed: %@",
        recognitionStopped: "Recognition stopped.",
        interrupted: "Interrupted."
    )

    static let chineseSimplified = SpeechServiceMessages(
        speechNotAvailable: "语音识别不可用。",
        micDeniedSettings: "麦克风权限被拒绝。请在 设置 → 隐私 → 麦克风中开启。",
        micDenied: "麦克风权限被拒绝。请在 设置 → 隐私 → 麦克风中开启。",
        micUnavailable: "麦克风不可用。",
        unsupportedLocale: "不支持「%@」的语音识别，请尝试其他语言。",
        localeUnavailable: "当前设备暂时无法使用「%@」的语音识别。可尝试英语、检查网络或稍后再试。",
        micUseFailed: "无法使用麦克风：%@",
        micInputUnavailable: "此设备没有可用的麦克风输入。",
        audioStartFailed: "无法启动音频：%@",
        nothingToStop: "尚未开始聆听，无需停止。",
        speechDeniedSettings: "语音识别已关闭。请在 设置 → 隐私 → 语音识别中开启。",
        speechRestricted: "此设备限制使用语音识别。",
        speechNotDetermined: "需要语音识别权限。",
        speechNotAllowed: "不允许使用语音识别。",
        noSpeechDetected: "未检测到语音，请靠近麦克风再试。",
        recognitionCanceled: "识别已取消。",
        recognitionFailedFormat: "语音识别失败：%@",
        recognitionStopped: "识别已停止。",
        interrupted: "已中断。"
    )

    static let spanish = SpeechServiceMessages(
        speechNotAvailable: "El reconocimiento de voz no está disponible.",
        micDeniedSettings: "Micrófono denegado. Actívalo en Ajustes → Privacidad → Micrófono.",
        micDenied: "Micrófono denegado. Actívalo en Ajustes → Privacidad → Micrófono.",
        micUnavailable: "El micrófono no está disponible.",
        unsupportedLocale: "No hay reconocimiento de voz para «%@». Prueba otro idioma.",
        localeUnavailable: "El reconocimiento de voz no está disponible para «%@» ahora. Prueba en inglés, revisa la red o inténtalo más tarde.",
        micUseFailed: "No se pudo usar el micrófono: %@",
        micInputUnavailable: "No hay entrada de micrófono en este dispositivo.",
        audioStartFailed: "No se pudo iniciar el audio: %@",
        nothingToStop: "Nada que detener — empieza a escuchar primero.",
        speechDeniedSettings: "Reconocimiento de voz desactivado. Actívalo en Ajustes → Privacidad → Reconocimiento de voz.",
        speechRestricted: "El reconocimiento de voz está restringido en este dispositivo.",
        speechNotDetermined: "Se necesita permiso de reconocimiento de voz.",
        speechNotAllowed: "No se permite el reconocimiento de voz.",
        noSpeechDetected: "No se detectó voz. Inténtalo de nuevo, más cerca del micrófono.",
        recognitionCanceled: "Reconocimiento cancelado.",
        recognitionFailedFormat: "Falló el reconocimiento de voz: %@",
        recognitionStopped: "Reconocimiento detenido.",
        interrupted: "Interrumpido."
    )
}

extension PermissionStatus {
    func label(strings: AppStrings) -> String {
        switch self {
        case .notDetermined: return strings.statusNotAsked
        case .granted: return strings.statusAllowed
        case .denied: return strings.statusDenied
        case .restricted: return strings.statusRestricted
        case .provisional: return strings.statusProvisional
        case .unknown: return strings.statusUnknown
        }
    }
}
