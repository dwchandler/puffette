defmodule Puffette do
  # $ mix run -e Puffette.run
  require Logger

  @factoid_file 'factoid.tab'
  @seen_file    'seen.tab'
  @karma_file   'karma.tab'
  @server       'chat.freenode.net'
  @nick         "puffette"
  @name         "Puffette"
  @channels     ["#puffette","#metabug"]

  defmodule State do
    defstruct socket: nil, seen: nil, karma: nil, factoid: nil
  end

  def run do
    Logger.configure_backend(:console, format: "$date $time [$level] $metadata$message\n")
    Logger.configure([level: :info])

    {result, data} = :ets.file2tab(@factoid_file)
    if result == :ok do
      factoid_table = data
    else
      factoid_table = :ets.new(:factoid, [])
    end

    {result, data} = :ets.file2tab(@seen_file)
    if result == :ok do
      seen_table = data
    else
      seen_table = :ets.new(:seen, [])
    end

    {result, data} = :ets.file2tab(@karma_file)
    if result == :ok do
      karma_table = data
    else
      karma_table = :ets.new(:karma, [])
    end

    {:ok, socket} = connect(@server)
    :ok = login(socket, @nick, @name)
    state = %State{socket: socket, seen: seen_table, karma: karma_table, factoid: factoid_table }
    response_loop(state)
  end
  
  def connect(host, port \\ 6667) do
    if is_binary(host) do
      host = to_char_list(host)
    end
    {:ok, socket} = :gen_tcp.connect(host, port, [:binary, active: false, packet: :line])
    Logger.info "Connected to #{host}:#{port}"
    {:ok, socket}
  end
  
  def login(socket, nick, name) do
    :ok = sendmsg(socket, "NICK #{nick}")
    :ok = sendmsg(socket, "USER #{nick} 8 * :#{name}")
  end
  
  def response_loop(state) do
    {:ok, data} = :gen_tcp.recv(state.socket, 0)
    data = String.strip(data)
    Logger.info data
    handle_event(state, data)
    response_loop(state)
  end
  
  def handle_event(state, "PING :" <> server) do
    sendmsg(state.socket, "PONG :" <> server)
  end

  def handle_event(state, ":" <> rest) do
    msg = String.split(rest)
    respond_msg(state, msg)
  end

  def handle_event(_socket, _data) do
    Logger.debug "handle_event: catch-all"
  end

  def respond_msg(state, [_server_name, "001", @nick | _rest]) do
    #:irc.server.com 001 nick :Welcome to the EFnet Internet Relay Chat Network
    for chan <- @channels, do: sendmsg(state.socket, "JOIN #{chan}")
  end

  def respond_msg(_socket, ["#{@nick}!~#{@nick}@"<>_hostname, "MODE", @nick | _rest]) do
    #:nick~user@host.example.com MODE nick :+i
    # TODO: Remember mode settings for ourself and others
  end

  # We join
  def respond_msg(_state, ["#{@nick}!~#{@nick}@"<>_hostname, "JOIN", ":"<>_chan]) do
    #sendmsg(state.socket, "PRIVMSG #{chan} :Hi!")
  end

  # Other joins
  def respond_msg(_state, [_fulluser, "JOIN", ":#"<>_chan]) do
    #{nick,user,host} = parse_nick(fulluser)
    #sendmsg(state.socket, "PRIVMSG ##{chan} :#{nick}: Welcome to ##{chan}!")
  end

  def respond_msg(state, [_fulluser, "INVITE", @nick, ":#"<>chan]) do
    sendmsg(state.socket, "JOIN ##{chan}")
  end

  # CTCP VERSION
  def respond_msg(state, [fulluser, "PRIVMSG", @nick, ":" <> <<1>> <> "VERSION" <> <<1>>]) do
    {nick,_user,_host} = parse_nick(fulluser)
    sendmsg(state.socket, "NOTICE #{nick} :" <> <<1>> <> "VERSION Puffette 0.1 - https://github.com/dwchandler/puffette" <> <<1>>)
  end

  # General PRIVMSG
  def respond_msg(state, [fulluser, "PRIVMSG", msg_dest, ":"<>first | rest]) do
    userinfo = parse_nick(fulluser)
    destinfo = if String.at(msg_dest,0) == "#", do: {:chan, msg_dest}, else: {:user, msg_dest}
    msg = [first | rest]
    handle_privmsg(state, userinfo, destinfo, msg)
  end

  def respond_msg(_state, [who, kind | rest]) do
    Logger.debug "respond_msg: catch-all: who=[#{inspect(who)}] kind=[#{inspect(kind)}] rest=[#{inspect(rest)}]"
  end

  # private chat
  def handle_privmsg(state, userinfo, {:user, @nick}, words) do
    {nick,_,_} = userinfo
    handle_addressed(state, userinfo, nick, words)
  end

  # addressed in channel
  def handle_privmsg(state, userinfo, {:chan, chan}, ["#{@nick}:" | words]) do
    record_last_utterance(state, userinfo, chan, Enum.join(["#{@nick}:" | words], " "))
    handle_addressed(state, userinfo, chan, words)
  end

  # channel chatter
  def handle_privmsg(state, userinfo, {:chan, chan}, words) do
    record_last_utterance(state, userinfo, chan, Enum.join(words, " "))
    cond do
      words == ["botsnack"] ->
        sendmsg(state.socket, "PRIVMSG #{chan} ::)")
      hd(words) == "seen" ->
        handle_seen(state, chan, hd(tl(words)))
      hd(words) == "karma" ->
        handle_karma(state, chan, hd(tl(words)))
      Enum.count(words) == 1 and String.ends_with?(hd(words), "++") ->
        record_karma(state, String.rstrip(hd(words), ?+), +1)
      Enum.count(words) == 1 and String.ends_with?(hd(words), "--") ->
        record_karma(state, String.rstrip(hd(words), ?-), -1)
      (entry = :ets.lookup(state.factoid, Enum.map(words, &String.upcase/1))) != [] ->
        handle_factoid(state, chan, entry)
      any_member?(words, ["is","are"]) ->
        record_factoid(state, userinfo, words)
      true ->
        Logger.debug "whatever..."
    end
  end

  def handle_addressed(state, {nick,user,_host}, dest, words) do
    Logger.info "HANDLE_ADDRESSED. Words = '#{inspect(words)}'"
    owner = (nick == "dwc" or nick == "dwchandler") and
            (user == "dwc" or user == "dchandler" or user == "dwchandler")
    cond do
      owner and any_member?(words, ["quit","die"]) ->
          quit_bot(state)
      words == ["botsnack"] ->
        sendmsg(state.socket, "PRIVMSG #{dest} ::)")
      words == ["leave"] or words == ["go","away"] ->
        part_channel(state, dest, "ok")
      words == ["botsnack"] ->
        sendmsg(state.socket, "PRIVMSG #{dest} ::)")
      words == ["help"] ->
        sendmsg(state.socket, "PRIVMSG #{dest} :Can somebody help #{nick}? I'm just a bot...")
      hd(words) == "seen" ->
        handle_seen(state, dest, hd(tl(words)))
      hd(words) == "karma" ->
        handle_karma(state, dest, hd(tl(words)))
      (entry = :ets.lookup(state.factoid, Enum.map(words, &String.upcase/1))) != [] ->
        handle_factoid(state, dest, entry)
      true ->
        sendmsg(state.socket, "PRIVMSG #{dest} :#{nick}: huh?")
    end
  end

  @doc """
  Parses a nick/user/host string into its component parts.

  ## Example

      iex> Puffette.parse_nick("nick~user@host.example.com")
      {"nick", "user", "host.example.com"}

  """
  def parse_nick(fullname) do
    [nick|[rest]] = String.split(fullname, "!")
    [user|[host]] = String.split(rest, "@")
    user = String.lstrip(user, ?~)
    {nick, user, host}
  end

  def sendmsg(socket, msg) do
    Logger.info IO.ANSI.bright() <> msg <> IO.ANSI.normal()
    :gen_tcp.send(socket, "#{msg}\r\n")
  end

  def any_member?(collection, value_list) do
    Enum.any?(value_list, fn(x) -> Enum.member?(collection, x) end)
  end

  def quit_bot(state) do
    sendmsg(state.socket, "QUIT :ttfn")
    :gen_tcp.close(state.socket)
    save_data(state)
    Logger.flush
    System.halt(0)
  end

  def save_data(state) do
    :ok = :ets.tab2file(state.factoid,  @factoid_file)
    :ok = :ets.tab2file(state.seen,     @seen_file)
    :ok = :ets.tab2file(state.karma,    @karma_file)
  end

  def part_channel(state, channel, message \\ "ttfn") do
    sendmsg(state.socket, "PART #{channel} :#{message}")
  end
  
  def record_last_utterance(state, {nick,_,_}, where, phrase) do
    entry = [:calendar.local_time(), where, phrase]
    Logger.debug "Entry for #{nick} = #{inspect entry}"
    :ets.insert(state.seen, {nick, entry})
    :ok = :ets.tab2file(state.seen,     @seen_file)
  end

  def handle_seen(state, dest, who) do
    entry = :ets.lookup(state.seen, who)
    if entry == [] do
      response = "I haven't seen #{who} lately."
    else
      [{^who, [datetime, where, phrase]}] = entry
      response = "#{who} was last seen on #{where} at #{format_date_time(datetime)}, saying: #{phrase}"
    end
    sendmsg(state.socket, "PRIVMSG #{dest} :#{response}")
  end

  def record_karma(state, what, amount) do
    entry = :ets.lookup(state.karma, String.upcase(what))
    if Enum.empty?(entry) do
      count = 0
    else
      [{_, [count]}] = entry
    end
    count = count + amount
    :ets.insert(state.karma, {String.upcase(what),[count]})
    :ok = :ets.tab2file(state.karma,    @karma_file)
  end

  def handle_karma(state, dest, what) do
    entry = :ets.lookup(state.karma, String.upcase(what))
    if Enum.empty?(entry) do
      response = "#{what} has no karma."
    else
      [{_, [count]}] = entry
      response = "#{what} has a karma of #{count}"
    end
    sendmsg(state.socket, "PRIVMSG #{dest} :#{response}")
  end

  def record_factoid(state, {nick,_,_}, words) do
    index = Enum.find_index(words, fn(x) -> x == "is" or x == "are" end)
    if index != nil  and index > 0 and index <= 4 do
      item = Enum.map(Enum.take(words, index), &String.upcase/1)
      info = Enum.drop(words, index+1)
      pivot = Enum.take(Enum.drop(words, index), 1)
      Logger.info "#{IO.ANSI.bright()}Factoid#{IO.ANSI.normal()}: #{inspect item} #{inspect pivot} #{inspect info}"
      entry = [:calendar.local_time(), nick, pivot, info]
      :ets.insert(state.factoid, {item, entry})
      :ok = :ets.tab2file(state.factoid,  @factoid_file)
    end
  end

  def handle_factoid(state, dest, entry) do
      [{what, [{{_y,_m,_d},{_hh,_mm,_ss}}, _who, pivot, info]}] = entry
      sendmsg(state.socket, "PRIVMSG #{dest} :I heard that #{String.downcase(Enum.join(what," "))} #{pivot} #{Enum.join(info," ")}")
  end

  def format_date_time({{year, month, day}, {hour, minute, second}}) do
    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
      [year, month, day, hour, minute, second])
      |> List.flatten
      |> to_string
  end
end
