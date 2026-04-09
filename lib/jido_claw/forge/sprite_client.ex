defmodule JidoClaw.Forge.SpriteClient do
  def create(spec) do
    impl().create(spec)
  end

  def exec(client, command, opts \\ []) do
    impl_for(client).exec(client, command, opts)
  end

  def spawn(client, command, args, opts \\ []) do
    impl_for(client).spawn(client, command, args, opts)
  end

  def run(client, agent_type, args, opts \\ []) do
    mod = impl_for(client)

    if function_exported?(mod, :run, 4) do
      mod.run(client, agent_type, args, opts)
    else
      # Fallback to exec for clients that don't implement run
      command = Enum.join([agent_type | args], " ")
      mod.exec(client, command, opts)
    end
  end

  def write_file(client, path, content) do
    impl_for(client).write_file(client, path, content)
  end

  def read_file(client, path) do
    impl_for(client).read_file(client, path)
  end

  def inject_env(client, env) do
    impl_for(client).inject_env(client, env)
  end

  def destroy(client, sprite_id) do
    impl_for(client).destroy(client, sprite_id)
  end

  def impl_module, do: impl()

  defp impl do
    Application.get_env(:jido_claw, :forge_sprite_client, JidoClaw.Forge.SpriteClient.Fake)
  end

  defp impl_for(client) do
    mod = client.__struct__
    if function_exported?(mod, :impl_module, 0), do: mod.impl_module(), else: mod
  end
end
