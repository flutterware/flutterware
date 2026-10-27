/// Which door this process serves, for anything that writes down who did what.
///
/// One process is one door: the studio's window, `fw` in a terminal, or the
/// MCP server an agent talks to, which opens its own session for every call.
/// So this is set once, where each of those starts, and read wherever an
/// action is recorded.
enum Caller {
  /// The studio's own window: a person pressing a button.
  studio,

  /// `fw` run in a terminal. A person, or an agent with a shell; nothing here
  /// can tell which.
  terminal,

  /// The MCP server, which only an agent's client talks to.
  agent,
}

/// What this process is. The studio unless its entry point said otherwise.
Caller currentCaller = Caller.studio;
