import 'package:flutter/material.dart';

import '../../copy_button.dart';
import '../../markdown_text.dart';
import '../../theme.dart';
import 'code_agent_controller.dart';
import 'tool_approval.dart';
import 'tool_approval_dialog.dart';

/// Icon per tool name, for the collapsed [_ToolCallRow]. Names are
/// opencode's own built-in tools (confirmed against a running `opencode
/// serve`'s OpenAPI spec and docs) — falls back to a generic build icon for
/// anything else (`task`, `todowrite`, `webfetch`, `websearch`, `skill`,
/// `lsp`, `question`, or an MCP-provided tool).
IconData _iconFor(String toolName) => switch (toolName) {
      'read' => Icons.description_outlined,
      'list' => Icons.folder_outlined,
      'glob' || 'grep' => Icons.search,
      'write' || 'edit' || 'patch' => Icons.edit_outlined,
      'bash' => Icons.terminal,
      _ => Icons.build_outlined,
    };

class CodeAgentPane extends StatefulWidget {
  const CodeAgentPane({super.key, required this.controller});

  final CodeAgentController controller;

  @override
  State<CodeAgentPane> createState() => _CodeAgentPaneState();
}

class _CodeAgentPaneState extends State<CodeAgentPane> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  CodeAgentController get _c => widget.controller;

  bool _dialogShowing = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChanged);
    _c.approvalRequests.listen(_showApprovalDialog);
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_c.running) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _showApprovalDialog(ToolApprovalRequest request) async {
    if (!mounted) {
      request.completer.complete(ToolApprovalDecision.deny);
      return;
    }
    // Only one approval is ever pending at a time — the agent loop awaits
    // this call before requesting the next tool call — but guard anyway so a
    // stray second event can't stack dialogs.
    if (_dialogShowing) return;
    _dialogShowing = true;
    await showDialog<ToolApprovalDecision>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ToolApprovalDialog(request: request),
    );
    _dialogShowing = false;
  }

  void _submit() {
    final text = _input.text;
    if (!_c.canSend || text.trim().isEmpty) return;
    _c.send(text);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        return Column(
          children: [
            if (_c.engineReady == false) _buildEngineCard(),
            Expanded(
              child: _c.transcript.isEmpty ? _buildEmptyState() : _buildTranscript(),
            ),
            _buildInput(),
          ],
        );
      },
    );
  }

  /// Shown while `llama-server` or `opencode` can't be found: the Code tab can't
  /// do anything without them, so this is where the user fixes that, rather than
  /// discovering it as a failed first message.
  Widget _buildEngineCard() {
    final installing = _c.engineInstalling;
    final progress = _c.engineProgress;
    final error = _c.engineInstallError;
    final megabytes = (_c.engineInstallBytes / 1000000).round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.deepPurple.shade300.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.download_for_offline_outlined,
                        size: 18, color: Colors.deepPurple.shade200),
                    const SizedBox(width: 8),
                    const Text('The Code tab needs two programs',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _c.engineCanInstall
                      ? 'llama-server runs the model and opencode is the coding agent. '
                          "They install into this app's own folder (about $megabytes MB) "
                          '— nothing is added to your PATH or system.'
                      : 'llama-server (from llama.cpp) runs the model and opencode is the '
                          'coding agent. Install both yourself and put them on PATH — see the '
                          'README "Code tab" section — then check again.',
                  style: const TextStyle(fontSize: 12, height: 1.45, color: Colors.white70),
                ),
                if (installing) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progress?.fraction),
                  const SizedBox(height: 6),
                  Text(progress?.message ?? 'Starting…',
                      style: const TextStyle(fontSize: 11, color: Colors.white54)),
                ] else ...[
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(error, style: TextStyle(fontSize: 12, color: Colors.red.shade300)),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _c.engineCanInstall
                        ? FilledButton.icon(
                            onPressed: _c.installEngine,
                            icon: const Icon(Icons.download, size: 18),
                            label: Text(error == null
                                ? 'Install (~$megabytes MB)'
                                : 'Try again'),
                          )
                        : OutlinedButton(
                            onPressed: _c.refreshEngine,
                            child: const Text('Check again'),
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final needsSetup = _c.projectRoot == null || _c.selectedModel == null;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.code, size: 52, color: Colors.deepPurple.shade200),
              const SizedBox(height: 16),
              const Text('Code',
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white)),
              const SizedBox(height: 10),
              const Text(
                'A local agent that reads and edits files and runs commands in '
                'a real project. It asks before writing anything or running a '
                'command.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.5, color: Colors.white38),
              ),
              const SizedBox(height: 12),
              Text(
                needsSetup
                    ? 'Choose a project folder and a model in the sidebar to start.'
                    : 'Ready — ask it something below.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    color: needsSetup ? Colors.white30 : Colors.deepPurple.shade200),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTranscript() {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          children: [
            for (final entry in _c.transcript) _buildEntry(entry),
            if (_c.error != null) ...[
              const SizedBox(height: 12),
              Text(_c.error!, style: TextStyle(color: Colors.red.shade300)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEntry(CodeTranscriptEntry entry) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: switch (entry) {
        UserTranscriptEntry() => _UserBubble(text: entry.text),
        AssistantTextTranscriptEntry() => _AssistantTextCard(text: entry.text),
        ToolCallTranscriptEntry() => _ToolCallRow(entry: entry),
      },
    );
  }

  Widget _buildInput() {
    final running = _c.running;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: _buildInputField(running),
        ),
      ),
    );
  }

  Widget _buildInputField(bool running) {
    return Container(
      padding: const EdgeInsets.only(left: 20, right: 8),
      decoration: BoxDecoration(
        color: cardColor,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              enabled: !running,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: _c.canSend || running
                    ? 'Ask the Code assistant to do something'
                    : _c.engineReady == false
                        ? 'Install the Code engine above first'
                        : 'Choose a project folder and a model first',
                hintStyle: const TextStyle(color: Colors.white38),
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: Colors.deepPurple.shade400,
                disabledBackgroundColor: Colors.white10,
              ),
              tooltip: running ? 'Stop' : 'Send',
              icon: Icon(running ? Icons.stop_rounded : Icons.arrow_upward,
                  size: 20, color: Colors.white),
              onPressed: running ? _c.stop : (_c.canSend ? _submit : null),
            ),
          ),
        ],
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.deepPurple.shade400,
          borderRadius: BorderRadius.circular(18),
        ),
        child: SelectableText(text, style: const TextStyle(color: Colors.white, height: 1.4)),
      ),
    );
  }
}

class _AssistantTextCard extends StatelessWidget {
  const _AssistantTextCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 700),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            MarkdownText(text, baseStyle: const TextStyle(height: 1.5, color: Colors.white)),
            if (text.isNotEmpty) ...[
              const SizedBox(height: 4),
              CopyButton(text),
            ],
          ],
        ),
      ),
    );
  }
}

/// The Claude-Code-like collapsed row for one tool call: a single line with
/// an icon, the call, and a status chip, expandable on tap to show the full
/// arguments and result — collapsed by default so tool activity doesn't
/// crowd out the actual conversation, the same way Claude Code keeps it out
/// of the way unless asked.
class _ToolCallRow extends StatefulWidget {
  const _ToolCallRow({required this.entry});

  final ToolCallTranscriptEntry entry;

  @override
  State<_ToolCallRow> createState() => _ToolCallRowState();
}

class _ToolCallRowState extends State<_ToolCallRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: Material(
          color: cardColor,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(_iconFor(entry.name), size: 15, color: Colors.white54),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('${entry.name}(${_shortArgs(entry)})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontFamily: 'monospace',
                                color: Colors.white70)),
                      ),
                      const SizedBox(width: 8),
                      _StatusChip(status: entry.status),
                      const SizedBox(width: 4),
                      Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                          size: 16, color: Colors.white38),
                    ],
                  ),
                  if (_expanded) ...[
                    const SizedBox(height: 8),
                    const Divider(height: 1, color: borderColor),
                    const SizedBox(height: 8),
                    Text('Arguments',
                        style: TextStyle(fontSize: 10, color: Colors.white38)),
                    const SizedBox(height: 2),
                    SelectableText(entry.argumentsJson,
                        style: const TextStyle(
                            fontSize: 11.5,
                            fontFamily: 'monospace',
                            height: 1.4,
                            color: Colors.white54)),
                    if (entry.resultText.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text('Result',
                          style: TextStyle(fontSize: 10, color: Colors.white38)),
                      const SizedBox(height: 2),
                      SelectableText(entry.resultText,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              height: 1.4,
                              color: entry.status == ToolCallStatus.error
                                  ? Colors.red.shade300
                                  : Colors.white54)),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _shortArgs(ToolCallTranscriptEntry entry) {
    final raw = entry.argumentsJson;
    return raw.length > 60 ? '${raw.substring(0, 60)}…' : raw;
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final ToolCallStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ToolCallStatus.running => ('Running', Colors.deepPurple.shade200),
      ToolCallStatus.awaitingApproval => ('Needs approval', Colors.amber),
      ToolCallStatus.done => ('Done', const Color(0xFF4ADE80)),
      ToolCallStatus.error => ('Failed', const Color(0xFFF87171)),
      ToolCallStatus.denied => ('Denied', Colors.white38),
    };
    return Text(label, style: TextStyle(fontSize: 10.5, color: color));
  }
}
