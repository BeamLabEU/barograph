defmodule Barograph.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Barograph.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Barograph.DatabaseSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Barograph.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
