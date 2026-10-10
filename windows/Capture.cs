using Windows.UI.Notifications;
using Windows.UI.Notifications.Management;

namespace NotifyFlash;

sealed record Banner(uint Id, string? App, string Title, string Body);

sealed class Seen
{
    // Why: WinRT has no empty UUID; treating ID zero as invalid is an unverified Windows hardware assumption.
    internal const uint InvalidId = 0;
    readonly Queue<uint> ids = new();
    readonly HashSet<uint> set = new();
    internal bool Accept(uint id, string? appName)
    {
        if (id == InvalidId || appName == null || !set.Add(id)) return false;
        ids.Enqueue(id);
        if (ids.Count > 64) set.Remove(ids.Dequeue());
        return true;
    }
}

sealed class Capture : IDisposable
{
    readonly Control dispatcher;
    readonly Action<Banner> received;
    readonly Seen seen = new();
    UserNotificationListener? listener;
    bool subscribed;
    volatile bool disposed;

    internal Capture(Control dispatcher, Action<Banner> received)
    {
        this.dispatcher = dispatcher; this.received = received;
    }

    internal async Task Start()
    {
        // Why: Unpackaged NotificationChanged can fail with 0x80070490; capture and glow remain unverified on Windows hardware.
        // Why: Keep the tray alive instead of exiting on a subscription failure, as required for diagnosis from the log.
        bool accessReported = false;
        try
        {
            listener = UserNotificationListener.Current;
            var access = await listener.RequestAccessAsync();
            Program.Log("RequestAccessAsync: " + access);
            accessReported = true;
            if (disposed) return;
            if (access != UserNotificationListenerAccessStatus.Allowed)
            {
                Program.Log("NotificationChanged: 購読失敗（通知アクセス未許可）");
                return;
            }
            listener.NotificationChanged += Changed;
            subscribed = true;
            Program.Log("NotificationChanged: 購読成功");
        }
        catch (Exception e)
        {
            var reason = $"{e.GetType().Name} HResult=0x{e.HResult:X8}: {e.Message}";
            if (!accessReported) Program.Log("RequestAccessAsync: 失敗 " + reason);
            Program.Log("NotificationChanged: 購読失敗 " + reason);
        }
    }

    void Changed(UserNotificationListener sender, UserNotificationChangedEventArgs args)
    {
        if (disposed || args.ChangeKind != UserNotificationChangedKind.Added) return;
        try
        {
            var notification = sender.GetNotification(args.UserNotificationId);
            if (notification == null) return;
            var app = notification.AppInfo?.DisplayInfo?.DisplayName;
            var binding = notification.Notification.Visual.GetBinding(KnownNotificationBindings.ToastGeneric);
            if (binding == null) return;
            var texts = binding.GetTextElements().Select(t => t.Text).ToArray();
            var banner = new Banner(args.UserNotificationId, app, texts.FirstOrDefault() ?? "", string.Join("\n", texts.Skip(1)));
            dispatcher.BeginInvoke((Action)(() =>
            {
                if (!disposed && Dispatch(args.ChangeKind, banner, seen)) received(banner);
            }));
        }
        catch (Exception e)
        {
            // Why: AppInfo throws E_NOTIMPL for senders whose AppUserModelId is not registered (e.g. portable WezTerm).
            if (!disposed) Program.Log($"通知抽出失敗: {e.GetType().Name} HResult=0x{e.HResult:X8}: {e.Message}（送信元の AppUserModelId が未登録の可能性）");
        }
    }

    internal static bool Dispatch(UserNotificationChangedKind kind, Banner? banner, Seen seen) =>
        kind == UserNotificationChangedKind.Added && banner != null && seen.Accept(banner.Id, banner.App);

    public void Dispose()
    {
        disposed = true;
        if (!subscribed || listener == null) return;
        subscribed = false;
        try { listener.NotificationChanged -= Changed; }
        catch (Exception e) { Program.Log("購読解除失敗: " + e.Message); }
    }

    internal static Dictionary<string, Func<bool>> CaptureSelfTests() => new()
    {
        ["D1"] = () =>
        {
            var seen = new Seen(); var banner = new Banner(1, "App", "t", "b");
            return Enumerable.Range(0, 3).Count(_ => Dispatch(UserNotificationChangedKind.Added, banner, seen)) == 1;
        },
        ["D2"] = () =>
        {
            var seen = new Seen();
            return new uint[] { 1, 2 }.Count(id => Dispatch(UserNotificationChangedKind.Added, new Banner(id, "App", "", ""), seen)) == 2;
        },
        ["D3"] = () => !Dispatch(UserNotificationChangedKind.Added, new Banner(Seen.InvalidId, "App", "", ""), new Seen()),
        ["D4"] = () =>
        {
            var seen = new Seen(); var banner = new Banner(1, "App", "", "");
            return Dispatch(UserNotificationChangedKind.Added, banner, seen)
                && !Dispatch(UserNotificationChangedKind.Removed, banner, seen)
                && !Dispatch(UserNotificationChangedKind.Added, banner, seen);
        },
        ["D5"] = () =>
        {
            var seen = new Seen();
            return !Dispatch(UserNotificationChangedKind.Added, new Banner(1, null, "", ""), seen)
                && Dispatch(UserNotificationChangedKind.Added, new Banner(1, "App", "", ""), seen);
        }
    };
}
