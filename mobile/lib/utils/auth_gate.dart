// Shared gate used by callers that want to require an account before
// running a sensitive action (Word/PDF export, etc.). Used by both
// the polish bubble and the chat-bubble actions menu so the gate
// behavior stays identical regardless of entry point.
//
// Pattern:
//
//   await runIfAuthed(
//     context, ref,
//     gateTitle: 'Save your work to Yve',
//     gateBody: 'Word and Markdown exports save your work outside Yve. '
//               'Create a free account to keep your work safe across devices.',
//     action: () => svc.shareAsWordDoc(...),
//   );
//
// If the user is currently authed, action() runs immediately. If they're
// anonymous, the AnonymousContinuationPanel opens. When the user signs
// in successfully from that panel, action() runs automatically — no
// re-tap of the original button required.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/account.dart';
import '../services/profile_service.dart';
import '../widgets/anonymous_continuation_panel.dart';

Future<void> runIfAuthed(
  BuildContext context,
  WidgetRef ref, {
  required Future<void> Function() action,
  String gateTitle = 'Save your work to Yve',
  String gateBody =
      'This action keeps something outside the app. '
      'Create a free account so your work follows you across devices.',
}) async {
  final AsyncValue<Account> accountAsync = ref.read(accountProvider);
  final Account? account = accountAsync.value;
  final bool isAnonymous = account?.isAnonymous ?? true;

  if (!isAnonymous) {
    await action();
    return;
  }

  if (!context.mounted) return;
  final bool authed = await showAnonymousContinuation(
    context,
    title: gateTitle,
    body: gateBody,
  );
  if (!authed || !context.mounted) return;

  // Brief wait so the entitlement notifier's auth listener picks up
  // the new session before we run the action — otherwise the action
  // might race with the listener and still see the old anonymous state.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  if (!context.mounted) return;
  await action();
}
