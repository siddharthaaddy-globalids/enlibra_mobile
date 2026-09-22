import 'package:flutter/material.dart';

import '../chat/chat_controller.dart';
import '../chat/context_budget.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.controller});

  final ChatController controller;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    widget.controller.initialize();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    // Keep the newest token in view while streaming.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    widget.controller.send(text);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final busy = c.status != ChatStatus.idle && c.status != ChatStatus.error;

    return Scaffold(
      appBar: AppBar(
        title: Text(c.conversation.title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: c.contextFraction,
            minHeight: 4,
            backgroundColor: Colors.transparent,
            color: c.contextFraction > 0.85
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: c.messages.length + (c.streamingText.isEmpty ? 0 : 1),
              itemBuilder: (context, i) {
                if (i < c.messages.length) {
                  return _Bubble(message: c.messages[i]);
                }
                return _Bubble(
                  message: StoredMessage(
                    id: -1,
                    role: 'assistant',
                    content: c.streamingText,
                    tokenCount: 0,
                  ),
                );
              },
            ),
          ),
          if (busy) _StatusBar(controller: c),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: !busy,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.all(12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Generation on a phone runs for tens of seconds. A stop
                  // control is not optional.
                  busy
                      ? IconButton.filled(
                          onPressed: c.stop,
                          icon: const Icon(Icons.stop),
                        )
                      : IconButton.filled(
                          onPressed: _send,
                          icon: const Icon(Icons.arrow_upward),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.controller});

  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    final label = switch (controller.status) {
      ChatStatus.restoring => 'Restoring conversation state',
      // Named explicitly because on a mid-range device this can take tens
      // of seconds, and silence reads as a frozen app.
      ChatStatus.prefilling => 'Reading the conversation',
      ChatStatus.generating => 'Writing',
      ChatStatus.summarizing => 'Compacting older messages',
      _ => '',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          if (controller.lastTokensPerSecond != null)
            Text(
              '${controller.lastTokensPerSecond!.toStringAsFixed(1)} tok/s',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final StoredMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final scheme = Theme.of(context).colorScheme;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Opacity(
          // Summarized turns stay visible but are visibly out of context.
          opacity: message.summarized ? 0.5 : 1.0,
          child: SelectableText(message.content),
        ),
      ),
    );
  }
}
