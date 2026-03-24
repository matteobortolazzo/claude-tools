package ipc

// HookEvent represents a Claude Code hook event delivered via muxwatch notify.
type HookEvent struct {
	EventType        string `json:"event_type"`                   // hook_event_name from stdin
	SessionID        string `json:"session_id"`                   // Claude session ID
	TmuxPane         string `json:"tmux_pane"`                    // $TMUX_PANE (e.g. %5)
	NotificationType string `json:"notification_type,omitempty"`  // Notification events only
	ToolName         string `json:"tool_name,omitempty"`          // PreToolUse, PermissionRequest, PostToolUse events
	IsInterrupt      bool   `json:"is_interrupt,omitempty"`       // PostToolUseFailure: true if user pressed ESC
	Timestamp        string `json:"timestamp"`
}
