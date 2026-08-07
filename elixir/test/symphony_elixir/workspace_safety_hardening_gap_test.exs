defmodule SymphonyElixir.WorkspaceSafetyHardeningGapTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workspace

  test "workspace_key '.' and '..' get hash suffix" do
    dot_key = Workspace.workspace_key(".")
    dotdot_key = Workspace.workspace_key("..")

    assert dot_key != "."
    assert dotdot_key != ".."
    assert String.contains?(dot_key, "--")
    assert String.contains?(dotdot_key, "--")
    assert String.starts_with?(dot_key, ".--")
    assert String.starts_with?(dotdot_key, "..--")
  end

  test "workspace_key nil fallback avoids collision with literal 'issue'" do
    nil_key = Workspace.workspace_key(nil)
    literal_key = Workspace.workspace_key("issue")

    assert nil_key != "issue"
    assert nil_key != literal_key
    assert String.contains?(nil_key, "--")
    assert literal_key == "issue"
  end

  test "remote workspace validation hardens Path.join traversal" do
    source = workspace_source()

    assert source =~ "remote_workspace_traversal?"
    assert source =~ "invalid_workspace_cwd"
    assert source =~ "/../"
    assert String.contains?(source, "String.contains?")

    # "." and ".." are sanitized to hash suffix, so the resulting path stays under root
    # and does not trigger traversal — this verifies the hash suffix is the intended hardening.
    dot_key = Workspace.workspace_key(".")
    dotdot_key = Workspace.workspace_key("..")
    assert dot_key =~ "--"
    assert dotdot_key =~ "--"

    # Crafted traversal identifier is sanitized ("/" -> "_") and hashed, so it stays contained
    traversal_key = Workspace.workspace_key("../evil")
    assert traversal_key =~ "--"
    refute String.contains?(traversal_key, "/")
  end

  test "before_remove remote uses atomic cd && guard" do
    source = workspace_source()

    assert source =~ "maybe_run_before_remove_hook(workspace, worker_host)"
    assert source =~ ~s("  cd \\"$workspace\\" &&)

    # Old non-atomic pattern (two-line cd then command) must be gone — check that
    # the old interpolating bare `cd "$workspace"` without && is not present as a script line.
    refute source =~ "\"  cd \\\"$workspace\\\"\","
  end

  defp workspace_source do
    candidates = [
      Path.join([File.cwd!(), "lib", "symphony_elixir", "workspace.ex"]),
      Path.expand("../../lib/symphony_elixir/workspace.ex", __DIR__),
      Path.expand("lib/symphony_elixir/workspace.ex", File.cwd!())
    ]

    Enum.find_value(candidates, fn path ->
      if File.exists?(path), do: File.read!(path)
    end) || File.read!(hd(candidates))
  end
end
