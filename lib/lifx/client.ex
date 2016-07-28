defmodule Lifx.Client do
    use GenServer
    use Lifx.Protocol.Types

    require Logger

    alias Lifx.Protocol.{FrameHeader, FrameAddress, ProtocolHeader}
    alias Lifx.Protocol.{Device, Packet}
    alias Lifx.Protocol.{HSBK}
    alias Lifx.Protocol
    alias Lifx.Device.State, as: Device
    alias Lifx.Client.PacketSupervisor
    alias Lifx.Device, as: Light

    @port 56700
    @multicast {255, 255, 255, 255}

    defmodule State do
        defstruct udp: nil,
            source: 0,
            events: nil,
            handlers: []
    end

    def start_link do
        GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    end

    def discover do
        GenServer.call(__MODULE__, :discover)
    end

    def set_color(%HSBK{} = hsbk, duration \\ 1000) do
        GenServer.call(__MODULE__, {:set_color, hsbk, duration})
    end

    def send(%Device{} = device, %Packet{} = packet, payload \\ <<>>) do
        GenServer.call(__MODULE__, {:send, device, packet, payload})
    end

    def add_handler(handler) do
        GenServer.call(__MODULE__, {:handler, handler})
    end

    def init(:ok) do
        udp_options = [
            :binary,
            {:broadcast, true},
            {:ip, {0,0,0,0}},
            {:reuseaddr, true}
        ]
        source = :rand.uniform(4294967295)
        {:ok, events} = GenEvent.start_link([{:name, Lifx.Client.Events}])
        Logger.info("Client: #{source}")
        {:ok, udp} = :gen_udp.open(0 , udp_options)
        Process.send_after(self(), :discover, 100)
        {:ok, %State{:udp => udp, :source => source}}
    end

    def handle_call({:send, device, packet, payload}, _from, state) do
        :gen_udp.send(state.udp, device.host, device.port, %Packet{packet |
            :frame_header => %FrameHeader{packet.frame_header |
                :source => state.source
            }
        } |> Protocol.create_packet(payload))
        {:reply, :ok, state}
    end

    def handle_call({:set_color, %HSBK{} = hsbk, duration}, _from, state) do
        payload = Protocol.hsbk(hsbk, duration)
        :gen_udp.send(state.udp, @multicast, @port, %Packet{
            :frame_header => %FrameHeader{:source => state.source, :tagged => 1},
            :frame_address => %FrameAddress{:ack_required => 1, :res_required => 1},
            :protocol_header => %ProtocolHeader{:type => @light_setcolor}
        } |> Protocol.create_packet(payload))
        {:reply, :ok, state}
    end

    def handle_call(:discover, _from, state) do
        send_discovery_packet(state.source, state.udp)
        {:reply, :ok, state}
    end

    def handle_call({:handler, handler}, {pid, _} = from, state) do
        GenEvent.add_mon_handler(state.events, handler, pid)
        {:reply, :ok, %{state | :handlers => [{handler, pid} | state.handlers]}}
    end

    def handle_info({:gen_event_EXIT, handler, reason}, state) do
        Enum.each(state.handlers, fn(h) ->
            GenEvent.add_mon_handler(state.events, elem(h, 0), elem(h, 1))
        end)
        {:noreply, state}
    end

    def handle_info(:discover, state) do
        send_discovery_packet(state.source, state.udp)
        {:noreply, state}
    end

    def handle_info({:udp, _s, ip, _port, payload}, state) do
        Task.Supervisor.start_child(PacketSupervisor, fn -> process(ip, payload, state) end)
        {:noreply, state}
    end

    def handle_packet(%Packet{:protocol_header => %ProtocolHeader{:type => @stateservice}} = packet, ip, state) do
        d = %Device{
            :id => packet.frame_address.target,
            :host => ip,
            :port => packet.payload.port
        }
        case Process.whereis(d.id) do
            nil -> Lifx.DeviceSupervisor.start_device(d)
            _ -> true
        end
    end

    def handle_packet(%Packet{:frame_address => %FrameAddress{:target => target}} = packet, _ip, _state) do
        Light.handle_packet(target, packet)
    end

    def process(ip, payload, state) do
        payload
        |> Protocol.parse_packet
        |> handle_packet(ip, state)
    end

    def send_discovery_packet(source, udp) do
        :gen_udp.send(udp, @multicast, @port, %Packet{
            :frame_header => %FrameHeader{:source => source, :tagged => 1},
            :frame_address => %FrameAddress{:res_required => 1},
            :protocol_header => %ProtocolHeader{:type => @getservice}
        } |> Protocol.create_packet)
    end

end
