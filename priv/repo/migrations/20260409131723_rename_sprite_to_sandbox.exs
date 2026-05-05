defmodule JidoClaw.Repo.Migrations.RenameSpriteToSandbox do
  @moduledoc """
  Renames sprite columns to sandbox equivalents for data preservation.

  Hand-edited from auto-generated remove+add to use rename.
  """

  use Ecto.Migration

  def up do
    rename(table(:forge_sessions), :sprite_id, to: :sandbox_id)
    rename(table(:forge_checkpoints), :sprites_checkpoint_id, to: :sandbox_checkpoint_id)
  end

  def down do
    rename(table(:forge_sessions), :sandbox_id, to: :sprite_id)
    rename(table(:forge_checkpoints), :sandbox_checkpoint_id, to: :sprites_checkpoint_id)
  end
end
