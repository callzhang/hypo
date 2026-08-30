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

    public PairingWindow(PairingViewModel model, HypoClient client)
    {
        _model = model;
        InitializeComponent();

        client.LanPeerConnected += (_, peer) => Dispatcher.Invoke(() =>
        {
            _model.Observe(peer);
            Bind();
        });

        Bind();
    }

    private void Bind()
    {
        Peers.ItemsSource = _model.Peers;
        Message.Text = _model.LastMessage ?? string.Empty;
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
