import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_controller.dart';
import '../chat/context_budget.dart';
import 'app_logo.dart';
import 'theme.dart';
import 'theme_controller.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.controller,
    required this.themeController,
  });

  final ChatController controller;
  final ThemeController themeController;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();

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
    _inputFocus.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
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
    // Keeps the keyboard up on mobile so a follow-up needs no extra tap.
    _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final t = context.tokens;
    final busy = c.status != ChatStatus.idle && c.status != ChatStatus.error;
    final isEmpty = c.messages.isEmpty && c.streamingText.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(c.conversation.title),
        actions: [
          _ContextMeter(fraction: c.contextFraction),
          const SizedBox(width: 4),
          ThemeToggleButton(controller: widget.themeController),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: isEmpty
                ? const _EmptyState()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    itemCount:
                        c.messages.length + (c.streamingText.isEmpty ? 0 : 1),
                    itemBuilder: (context, i) {
                      if (i < c.messages.length) {
                        return _Message(message: c.messages[i]);
                      }
                      return _Message(
                        message: StoredMessage(
                          id: -1,
                          role: 'assistant',
                          content: c.streamingText,
                          tokenCount: 0,
                        ),
                        streaming: true,
                      );
                    },
                  ),
          ),
          if (busy) _StatusStrip(controller: c),
          _Composer(
            input: _input,
            focusNode: _inputFocus,
            enabled: !busy,
            busy: busy,
            onSend: _send,
            onStop: c.stop,
            borderColor: t.border,
          ),
        ],
      ),
    );
  }
}

/// Constrains children to a readable measure and centres them.
class _Centered extends StatelessWidget {
  const _Centered({required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppTheme.maxContentWidth),
        child: Padding(
          padding: padding ?? const EdgeInsets.symmetric(horizontal: 20),
          child: child,
        ),
      ),
    );
  }
}

/// A single turn.
///
/// The asymmetry is the point: user turns sit in a contained, right-aligned
/// card, assistant turns are plain text on the page. Wrapping model output
/// in a bubble makes long replies feel boxed in and wastes horizontal space
/// exactly where the reading happens.
class _Message extends StatelessWidget {
  const _Message({required this.message, this.streaming = false});

  final StoredMessage message;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final isUser = message.role == 'user';

    return _Centered(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Opacity(
          // Summarized turns stay readable but are visibly out of context.
          opacity: message.summarized ? 0.45 : 1,
          child: isUser
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: t.userMessage,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: t.border),
                        ),
                        child: SelectableText(
                          message.content,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _AssistantLabel(streaming: streaming),
                    const SizedBox(height: 6),
                    SelectableText(
                      message.content,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    if (!streaming && message.content.isNotEmpty)
                      _CopyButton(text: message.content),
                  ],
                ),
        ),
      ),
    );
  }
}

class _AssistantLabel extends StatelessWidget {
  const _AssistantLabel({required this.streaming});

  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: t.accent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: const Icon(Icons.auto_awesome, size: 12, color: Colors.white),
        ),
        const SizedBox(width: 8),
        Text('Assistant', style: Theme.of(context).textTheme.titleSmall),
        if (streaming) ...[
          const SizedBox(width: 8),
          _TypingDot(color: t.accent),
        ],
      ],
    );
  }
}

class _TypingDot extends StatefulWidget {
  const _TypingDot({required this.color});
  final Color color;

  @override
  State<_TypingDot> createState() => _TypingDotState();
}

class _TypingDotState extends State<_TypingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.25, end: 1).animate(_c),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text});
  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 28),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: widget.text));
          if (!mounted) return;
          setState(() => _copied = true);
          await Future<void>.delayed(const Duration(seconds: 2));
          if (mounted) setState(() => _copied = false);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _copied ? Icons.check : Icons.content_copy_outlined,
                size: 13,
                color: _copied ? t.accent : t.textFaint,
              ),
              const SizedBox(width: 5),
              Text(
                _copied ? 'Copied' : 'Copy',
                style: TextStyle(
                  fontSize: 12,
                  color: _copied ? t.accent : t.textFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: _Centered(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const AppLogo(height: 34),
            const SizedBox(height: 22),
            Text(
              'How can I help today?',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w500,
                color: t.text,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Running entirely on this device.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Thin bar showing how full the context window is.
///
/// Users deserve to see this before the app silently starts compacting
/// their history away.
class _ContextMeter extends StatelessWidget {
  const _ContextMeter({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tight = fraction > 0.85;
    return Tooltip(
      message: 'Context ${(fraction * 100).round()}% full',
      child: Container(
        width: 34,
        height: 4,
        decoration: BoxDecoration(
          color: t.border,
          borderRadius: BorderRadius.circular(2),
        ),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: fraction.clamp(0.0, 1.0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tight ? AppColors.danger : t.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.controller});

  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final label = switch (controller.status) {
      ChatStatus.restoring => 'Restoring conversation',
      // Named explicitly: on a mid-range device this stage can run for tens
      // of seconds, and unexplained silence reads as a frozen app.
      ChatStatus.prefilling => 'Reading the conversation',
      ChatStatus.generating => 'Writing',
      ChatStatus.summarizing => 'Compacting older messages',
      _ => '',
    };

    return _Centered(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Row(
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: t.accent),
          ),
          const SizedBox(width: 10),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          if (controller.lastTokensPerSecond != null)
            Text(
              '${controller.lastTokensPerSecond!.toStringAsFixed(1)} tok/s',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.input,
    required this.focusNode,
    required this.enabled,
    required this.busy,
    required this.onSend,
    required this.onStop,
    required this.borderColor,
  });

  final TextEditingController input;
  final FocusNode focusNode;
  final bool enabled;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return SafeArea(
      top: false,
      child: _Centered(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Container(
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: input,
                  focusNode: focusNode,
                  enabled: enabled,
                  minLines: 1,
                  maxLines: 6,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    hintText: 'Reply to Assistant',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Generation runs for tens of seconds on a phone, so stop is
              // not a secondary action -- it occupies the primary slot for
              // as long as it is relevant.
              _CircleButton(
                icon: busy ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                background: busy ? t.surfaceRaised : t.accent,
                foreground: busy ? t.text : Colors.white,
                onTap: busy ? onStop : onSend,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(icon, size: 18, color: foreground),
        ),
      ),
    );
  }
}
