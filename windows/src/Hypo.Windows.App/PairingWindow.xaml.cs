using System.Windows;
using Hypo.Core.Client;
using Hypo.Windows.App;

namespace Hypo.Windows.App.Shell;

/// <summary>
/// Shows discoverable peers and pairs with one. The list, the "already paired"
/// marking and every outcome message come from <see cref="PairingViewModel"/>.
/// </summary>
public partial class PairingWindow : Window
{
    private readonly PairingViewModel _model;

    /// <param name="client">
    /// Optional. When present, peers discovered while the window is open appear
    /// in it; without one the list is whatever the view model already knows. The
    /// window is useful either way, and requiring a live client would make it
    /// impossible to show one in a test.
    /// </param>
    public PairingWindow(PairingViewModel model, HypoClient? client = null)
    {
        _model = model;
        InitializeComponent();

        if (client is not null)
        {
            client.LanPeerConnected += (_, peer) => Dispatcher.Invoke(() =>
            {
                _model.Observe(peer);
                Bind();
            });
        }

        Bind();
    }

    private void Bind()
    {
        Peers.ItemsSource = _model.Peers;
        Message.Text = _model.LastMessage ?? string.Empty;

        // Hidden rather than disabled-and-mysterious when there are no relay
        // credentials: an unusable control invites a bug report.
        var codeVisibility = _model.CanPairByCode ? Visibility.Visible : Visibility.Collapsed;
        CodeBox.Visibility = codeVisibility;
        UseCodeButton.Visibility = codeVisibility;
        ShowCodeButton.Visibility = codeVisibility;
    }

    private async void OnShowCode(object sender, RoutedEventArgs e)
    {
        ShowCodeButton.IsEnabled = false;
        UseCodeButton.IsEnabled = false;

        try
        {
            // Waits for someone to type it, which is why the buttons go away:
            // starting a second exchange while one is open would leave a code
            // on screen that nothing is listening for.
            await _model.ShowCodeAsync();
        }
        catch (Exception ex)
        {
            Message.Text = $"Could not get a code: {ex.Message}";
        }
        finally
        {
            ShowCodeButton.IsEnabled = true;
            UseCodeButton.IsEnabled = true;
            Bind();
        }
    }

    private async void OnUseCode(object sender, RoutedEventArgs e)
    {
        UseCodeButton.IsEnabled = false;
        ShowCodeButton.IsEnabled = false;

        try
        {
            await _model.UseCodeAsync(CodeBox.Text);
        }
        catch (Exception ex)
        {
            Message.Text = $"Could not use that code: {ex.Message}";
        }
        finally
        {
            UseCodeButton.IsEnabled = true;
            ShowCodeButton.IsEnabled = true;
            Bind();
        }
    }

    private async void OnPair(object sender, RoutedEventArgs e)
    {
        if (Peers.SelectedItem is not PairablePeer peer)
        {
            Message.Text = "Choose a device first.";
            return;
        }

        if (!peer.CanPair)
        {
            Message.Text = peer.AlreadyPaired
                ? $"Already paired with {peer.DisplayName}."
                : $"{peer.DisplayName} is not offering to pair. Open Hypo on it and try again.";
            return;
        }

        PairButton.IsEnabled = false;
        try
        {
            await _model.PairAsync(peer);
        }
        catch (Exception ex)
        {
            Message.Text = $"Pairing failed: {ex.Message}";
        }
        finally
        {
            PairButton.IsEnabled = true;
            Bind();
        }
    }
}
