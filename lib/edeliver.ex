defmodule Edeliver do
  @moduledoc """
    Execute edeliver tasks on the production / staging nodes.

    This internal module provides functions on the nodes which are
    used by some edeliver tasks e.g. to get the running release version
    (`edeliver version`), show the pending migrations
    (`edeliver show migrations`) or install pending migrations
    (`edeliver migrate`).

    In addition it represents the edeliver application callback module
    and starts a process registered locally as `Edeliver` which's onliest
    purpose is to be able to detect whether the release was successfully
    started. This requires to start edeliver as last application in the
    release.

  """
  use Application
  use GenServer

  @doc """
    Starts the edeliver application

    including the `Edeliver.Supervisor` process supervising the
    `Edeliver` generic server.
  """
  @spec start(term, term) :: {:ok, pid}
  def start(_type, _args) do
    import Supervisor.Spec, warn: false
    children = [worker(__MODULE__, [], name: __MODULE__)]
    options = [strategy: :one_for_one, name: Edeliver.Supervisor]
    Supervisor.start_link(children, options)
  end

  @doc "Starts this gen-server registered locally as `Edeliver`"
  @spec start_link() :: {:ok, pid}
  def start_link(), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
    Runs the edeliver command on the erlang node

    started as:
    ```
    bin/$APP rpc 'Elixir.Edeliver.run_command('[command_name, \"$APP\", arguments...])'
    ```

    The first argument must be the name of the command, the second argument the
    name  of the main application and all further arguments are passed to the
    function that's name is equal to the command name.
  """
  @spec run_command(args :: [term]) :: no_return
  def run_command([:monitor_startup_progress, application_name, :verbose]) do
    :error_logger.add_report_handler(Edeliver.StartupProgress)
    monitor_startup_progress(application_name)
    :error_logger.delete_report_handler(Edeliver.StartupProgress)
  end

  def run_command([:monitor_startup_progress, application_name | _]) do
    monitor_startup_progress(application_name)
  end

  def run_command([command_name, application_name | arguments]) when is_atom(command_name) do
    application_name = String.to_atom(application_name)

    {^application_name, _description, application_version} =
      :application.which_applications() |> List.keyfind(application_name, 0)

    application_version = to_string(application_version)
    apply(__MODULE__, command_name, [application_name, application_version | arguments])
  end

  @doc """
    Waits until the edeliver application is started.

    If the edeliver application is added as last application in the `:applications` section of
    the `application/0` fun in the `mix.exs` this waits until all applications are started.
    This can be used as rpc call after running the asynchronous `bin/$APP start` command to
    wait until all applications started and then return `ok`.
  """
  @spec monitor_startup_progress(application_name :: atom) :: :ok
  def monitor_startup_progress(application_name) do
    edeliver_pid = Process.whereis(__MODULE__)

    if is_pid(edeliver_pid) do
      :ok
    else
      receive do
      after
        500 -> :ok
      end

      monitor_startup_progress(application_name)
    end
  end

  @doc """
    Returns the running release version

    which is either the `:current` version or the `:permanent` version.
  """
  @spec release_version(atom) :: String.t() | nil
  @spec release_version(atom, String.t() | nil) :: String.t() | nil
  def release_version(application_name, _application_version \\ nil) do
    releases = :release_handler.which_releases()
    application_name = Atom.to_charlist(application_name)

    # Example of `releases`:
    # [
    #   {~c"loyalty", ~c"2.59.0+f08833be",
    #     [~c"elixir-1.14.5", ~c"mix-1.14.5", ~c"iex-1.14.5", ~c"sasl-4.1.2",
    #     ~c"compiler-8.1.1.5", ~c"stdlib-3.17.2.4", ~c"runtime_tools-1.18",
    #     ~c"admin_dashboard-2.59.0+f08833be", ~c"logger-1.14.5",
    #     ~c"api-2.59.0+f08833be", ~c"shopify_integration-2.59.0+f08833be",
    #     ~c"wx-2.1.4", ~c"observer-2.11.1", ~c"core-2.59.0+f08833be",
    #     ~c"crypto-5.0.6.4", ~c"common-2.59.0+f08833be", ~c"jason-1.4.4",
    #     ~c"appsignal-2.9.0", ~c"decimal-2.1.1", ~c"hackney-1.18.1",
    #     ~c"asn1-5.0.18.2", ~c"public_key-1.12.0.2", ~c"ssl-10.7.3.9",
    #     ~c"idna-6.1.1", ~c"unicode_util_compat-0.7.0", ~c"mimerl-1.3.0",
    #     ~c"certifi-2.9.0", ~c"parse_trans-3.3.1", ~c"syntax_tools-2.6",
    #     ~c"ssl_verify_fun-1.1.7", ~c"metrics-1.0.1", ~c"decorator-1.4.0",
    #     ~c"telemetry-1.2.1", ~c"oban_pro-1.4.2", ~c"oban_web-2.10.2",
    #     ~c"phoenix_html-3.3.3", ~c"phoenix_live_view-0.20.13", ~c"oban_met-0.1.4",
    #     ~c"ex_cldr-2.40.1", ~c"inets-7.5.3.4", ~c"ex_unit-1.14.5",
    #     ~c"cldr_utils-2.28.2", ~c"ex_cldr_calendars-1.26.2",
    #     ~c"ex_cldr_numbers-2.33.3", ~c"ex_cldr_currencies-2.16.3",
    #     ~c"digital_token-1.0.0", ...], :permanent}
    # ]

    releases
    |> Enum.find(fn {name, _version, _apps, status} ->
      if status in [:current, :permanent] do
        name == application_name
      end
    end)
    |> then(fn
      {_name, version, _apps, _status} -> to_string(version)
      _ -> nil
    end)
  end

  @doc """
    Prints the pending ecto migrations
  """
  def list_pending_migrations(application_name, application_version, ecto_repository \\ ~c"") do
    repository = ecto_repository!(application_name, ecto_repository)
    migrator = Ecto.Migrator
    versions = migrator.migrated_versions(repository)

    pending_migrations =
      migrations_for(migrations_dir(application_name, application_version))
      |> Enum.filter(fn {version, _name, _file} -> version not in versions end)
      |> Enum.reverse()
      |> Enum.map(fn {version, name, _file} -> {version, name} end)

    pending_migrations
    |> Enum.each(fn {version, name} ->
      warning("pending: #{name} (#{version})")
    end)
  end

  @doc """
    Runs the pending ecto migrations
  """
  def migrate(
        application_name,
        application_version,
        ecto_repository,
        direction,
        migration_version \\ :all
      )
      when is_atom(direction) do
    options =
      if migration_version == :all, do: [all: true], else: [to: to_string(migration_version)]

    migrator = Ecto.Migrator

    migrator.run(
      ecto_repository!(application_name, ecto_repository),
      migrations_dir(application_name, application_version),
      direction,
      options
    )
  end

  @doc """
    Returns the current directory containing the ecto migrations.
  """
  def migrations_dir(application_name, application_version) do
    # use priv dir from installed version
    lib_dir = :code.priv_dir(application_name) |> to_string |> Path.dirname() |> Path.dirname()
    application_with_version = "#{Atom.to_string(application_name)}-#{application_version}"
    Path.join([lib_dir, application_with_version, "priv", "repo", "migrations"])
  end

  def init(args) do
    {:ok, args}
  end

  defp ecto_repository!(_application_name, ecto_repository = [_ | _]) do
    # repository name was passed as ECTO_REPOSITORY env by the erlang-node-execute rpc call
    List.to_atom(ecto_repository)
  end

  defp ecto_repository!(application_name, _ecto_repository) do
    # ECTO_REPOSITORY env was set when the node was started
    case System.get_env("ECTO_REPOSITORY") do
      ecto_repository = <<_, _::binary>> ->
        ecto_repository_module = ecto_repository |> to_charlist |> List.to_atom()

        if maybe_ecto_repo?(ecto_repository_module) do
          ecto_repository_module
        else
          error!(
            "Module '#{ecto_repository_module}' is not an ecto repository.\n    Please set the correct repository module in the edeliver config as ECTO_REPOSITORY env\n    or remove that value to use autodetection of that module."
          )
        end

      _ ->
        case ecto_repos_from_config(application_name) do
          {:ok, [ecto_repository_module]} ->
            ecto_repository_module

          {:ok, modules = [_ | _]} ->
            error!(
              "Found several ecto repository modules (#{inspect(modules)}).\n    Please specify the repository to use in the edeliver config as ECTO_REPOSITORY env."
            )

          :error ->
            case Enum.filter(:erlang.loaded() |> Enum.reverse(), &ecto_1_0_repo?/1) do
              [ecto_repository_module] ->
                ecto_repository_module

              [] ->
                error!(
                  "No ecto repository module found.\n    Please specify the repository in the edeliver config as ECTO_REPOSITORY env."
                )

              modules = [_ | _] ->
                error!(
                  "Found several ecto repository modules (#{inspect(modules)}).\n    Please specify the repository to use in the edeliver config as ECTO_REPOSITORY env."
                )
            end
        end
    end
  end

  defp ecto_repos_from_config(application_name) do
    Application.fetch_env(application_name, :ecto_repos)
  end

  defp maybe_ecto_repo?(module) do
    if :erlang.module_loaded(module) do
      exports = module.module_info(:exports)
      # :__adapter__ for ecto versions >= 2.0, :__repo__ for ecto versions < 2.0
      Keyword.get(exports, :__adapter__, nil) || Keyword.get(exports, :__repo__, false)
    else
      false
    end
  end

  defp ecto_1_0_repo?(module) do
    if :erlang.module_loaded(module) do
      module.module_info(:exports)
      |> Keyword.get(:__repo__, false)
    else
      false
    end
  end

  # taken from https://github.com/elixir-lang/ecto/blob/master/lib/ecto/migrator.ex#L183
  defp migrations_for(directory) do
    query = Path.join(directory, "*")

    for entry <- Path.wildcard(query),
        info = extract_migration_info(entry),
        do: info
  end

  defp extract_migration_info(file) do
    base = Path.basename(file)
    ext = Path.extname(base)

    case Integer.parse(Path.rootname(base)) do
      {integer, "_" <> name} when ext == ".exs" -> {integer, name, file}
      _ -> nil
    end
  end

  # defp info(message),    do: IO.puts "==> #{IO.ANSI.green}#{message}#{IO.ANSI.reset}"
  defp warning(message), do: IO.puts("==> #{IO.ANSI.yellow()}#{message}#{IO.ANSI.reset()}")

  defp error!(message) do
    IO.puts("==> #{IO.ANSI.red()}#{message}#{IO.ANSI.reset()}")
    throw("error")
  end
end
