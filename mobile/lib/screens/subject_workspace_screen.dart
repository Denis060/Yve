import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/concept_mastery.dart';
import '../models/material_item.dart';
import '../models/study_mode.dart';
import '../models/study_session.dart';
import '../models/subject.dart';
import '../services/concepts_service.dart';
import '../services/materials_service.dart';
import '../services/sessions_service.dart';
import '../services/subjects_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';
import '../widgets/add_material_sheet.dart';
import 'chat_screen.dart';

/// Subject Workspace — the AI knowledge space for one subject.
///
/// Materials, Sessions, and Practice (concept mastery) tabs all read from
/// the Subject Memory schema. The FAB opens a chat scoped to this subject
/// in `materials` mode so retrieval auto-grounds against uploaded content.
class SubjectWorkspaceScreen extends ConsumerStatefulWidget {
  const SubjectWorkspaceScreen({super.key, required this.subjectId});

  final String subjectId;

  @override
  ConsumerState<SubjectWorkspaceScreen> createState() =>
      _SubjectWorkspaceScreenState();
}

class _SubjectWorkspaceScreenState
    extends ConsumerState<SubjectWorkspaceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<Subject?> subjectAsync =
        ref.watch(subjectByIdProvider(widget.subjectId));

    return Scaffold(
      body: subjectAsync.when(
        loading: () => const _LoadingShell(),
        error: (Object e, _) => _ErrorShell(message: e.toString()),
        data: (Subject? subject) {
          if (subject == null) {
            return const _ErrorShell(message: 'Subject not found.');
          }
          return Column(
            children: <Widget>[
              _Header(subject: subject),
              Container(
                color: YveColors.surface,
                child: TabBar(
                  controller: _tabs,
                  indicatorColor: YveColors.primary,
                  indicatorWeight: 2,
                  labelColor: YveColors.primary,
                  unselectedLabelColor: YveColors.textTertiary,
                  labelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  tabs: const <Widget>[
                    Tab(text: 'Materials'),
                    Tab(text: 'Sessions'),
                    Tab(text: 'Practice'),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: <Widget>[
                    _MaterialsTab(subject: subject),
                    _SessionsTab(subject: subject),
                    _PracticeTab(subject: subject),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton:
          subjectAsync.value == null ? null : _AskFab(subject: subjectAsync.value!),
    );
  }
}

class _LoadingShell extends StatelessWidget {
  const _LoadingShell();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

class _ErrorShell extends StatelessWidget {
  const _ErrorShell({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(YveSpacing.xl),
        child: Text(
          message,
          style: const TextStyle(color: YveColors.textSecondary),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.subject});
  final Subject subject;

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    return Container(
      decoration: const BoxDecoration(gradient: YveColors.brandGradient),
      padding: EdgeInsets.fromLTRB(
        YveSpacing.xl,
        topInset + 12,
        YveSpacing.xl,
        YveSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: () => Navigator.of(context).pop(),
            child: const Row(
              children: <Widget>[
                Icon(Icons.arrow_back_rounded,
                    size: 16, color: YveColors.textOnGradient),
                SizedBox(width: 4),
                Text(
                  'Subjects',
                  style: TextStyle(
                    fontSize: 13,
                    color: YveColors.textOnGradient,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: YveSpacing.md),
          Text(subject.emoji, style: const TextStyle(fontSize: 36)),
          const SizedBox(height: YveSpacing.sm),
          Text(
            subject.name,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: YveColors.textInverse,
            ),
          ),
          if (subject.subtitle != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              subject.subtitle!,
              style: const TextStyle(
                fontSize: 13,
                color: YveColors.textOnGradient,
              ),
            ),
          ],
          const SizedBox(height: YveSpacing.lg),
          Row(
            children: <Widget>[
              _Stat(label: 'Materials', value: subject.materialCount),
              const SizedBox(width: YveSpacing.lg),
              _Stat(label: 'Sessions', value: subject.sessionCount),
              const SizedBox(width: YveSpacing.lg),
              _Stat(label: 'Concepts', value: subject.conceptCount),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '$value',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: YveColors.textInverse,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: YveColors.textOnGradient,
          ),
        ),
      ],
    );
  }
}

class _AskFab extends ConsumerWidget {
  const _AskFab({required this.subject});
  final Subject subject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FloatingActionButton.extended(
      backgroundColor: YveColors.primary,
      foregroundColor: YveColors.textInverse,
      shape: const StadiumBorder(),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(
            subjectId: subject.id,
            subjectName: subject.name,
            subjectEmoji: subject.emoji,
            initialMode: StudyMode.materials,
          ),
        ),
      ),
      icon: const Icon(Icons.auto_awesome_rounded),
      label: Text('Ask Yve about ${subject.name}'),
    );
  }
}

class _MaterialsTab extends ConsumerStatefulWidget {
  const _MaterialsTab({required this.subject});
  final Subject subject;

  @override
  ConsumerState<_MaterialsTab> createState() => _MaterialsTabState();
}

class _MaterialsTabState extends ConsumerState<_MaterialsTab> {
  bool _ingesting = false;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<MaterialItem>> materialsAsync =
        ref.watch(materialsBySubjectProvider(widget.subject.id));

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(materialsBySubjectProvider(widget.subject.id));
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          YveSpacing.lg,
          YveSpacing.lg,
          YveSpacing.lg,
          100,
        ),
        children: <Widget>[
          _AddMaterialTile(
            loading: _ingesting,
            onTap: _ingesting ? null : _onAdd,
          ),
          const SizedBox(height: YveSpacing.sm),
          materialsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.only(top: YveSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (Object e, _) => _InlineError(message: e.toString()),
            data: (List<MaterialItem> items) {
              if (items.isEmpty) return const _EmptyMaterials();
              return Column(
                children: <Widget>[
                  for (final MaterialItem m in items) ...<Widget>[
                    _MaterialCard(item: m),
                    const SizedBox(height: YveSpacing.sm),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _onAdd() async {
    final AddMaterialResult? result = await showAddMaterialSheet(context);
    if (result == null || !mounted) return;
    setState(() => _ingesting = true);
    try {
      await ref.read(materialsRepositoryProvider).ingest(
            subjectId: widget.subject.id,
            kind: result.kind,
            name: result.name,
            content: result.content,
            url: result.url,
            pdfBytes: result.pdfBytes,
            docxBytes: result.docxBytes,
          );
      if (!mounted) return;
      ref.invalidate(materialsBySubjectProvider(widget.subject.id));
      ref.invalidate(subjectByIdProvider(widget.subject.id));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Indexed. You can ask Yve about it now.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppError.from(e, actionContext: 'index_material').userMessage,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _ingesting = false);
    }
  }
}

class _AddMaterialTile extends StatelessWidget {
  const _AddMaterialTile({required this.loading, required this.onTap});

  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: YveSpacing.lg),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFD1D5DB), width: 1.5),
        ),
        child: loading
            ? const Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: YveColors.primary,
                    ),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Yve is reading & indexing…',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: YveColors.primary,
                    ),
                  ),
                ],
              )
            : const Text(
                '+ Add material',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: YveColors.textSecondary,
                ),
              ),
      ),
    );
  }
}

class _EmptyMaterials extends StatelessWidget {
  const _EmptyMaterials();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: YveSpacing.xxxl),
      child: Column(
        children: <Widget>[
          const Icon(Icons.folder_open_rounded,
              size: 48, color: YveColors.textTertiary),
          const SizedBox(height: YveSpacing.sm),
          Text(
            'No materials yet',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          const Text(
            'Add notes, paste a URL, or upload a file.\nYve indexes them so she can ground future answers.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: YveColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: YveSpacing.lg),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 13, color: YveColors.error),
      ),
    );
  }
}

class _MaterialCard extends StatelessWidget {
  const _MaterialCard({required this.item});
  final MaterialItem item;

  ({IconData icon, Color tint}) _visual() {
    switch (item.kind) {
      case MaterialKind.pdf:
        return (icon: Icons.picture_as_pdf_rounded, tint: YveColors.tintRed);
      case MaterialKind.image:
        return (icon: Icons.image_rounded, tint: YveColors.tintPurple);
      case MaterialKind.note:
        return (icon: Icons.notes_rounded, tint: YveColors.tintAmber);
      case MaterialKind.url:
        return (icon: Icons.link_rounded, tint: YveColors.tintBlue);
      case MaterialKind.doc:
        return (icon: Icons.description_rounded, tint: YveColors.tintGreen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ({IconData icon, Color tint}) v = _visual();
    final bool failed = item.status == MaterialStatus.failed;
    return Container(
      padding: const EdgeInsets.all(YveSpacing.md),
      decoration: BoxDecoration(
        color: YveColors.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: v.tint,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(v.icon, color: YveColors.textPrimary),
          ),
          const SizedBox(width: YveSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(item.name, style: text.titleSmall),
                const SizedBox(height: 2),
                Text(
                  failed
                      ? (item.error ?? 'Indexing failed.')
                      : item.statusLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: failed ? YveColors.error : YveColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionsTab extends ConsumerWidget {
  const _SessionsTab({required this.subject});
  final Subject subject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<StudySession>> sessionsAsync =
        ref.watch(sessionsBySubjectProvider(subject.id));
    return sessionsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object e, _) => _InlineError(message: e.toString()),
      data: (List<StudySession> sessions) {
        if (sessions.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(YveSpacing.xl),
              child: Text(
                'No sessions yet.\nTap "Ask Yve" below to start one.',
                textAlign: TextAlign.center,
                style: TextStyle(color: YveColors.textSecondary),
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(
            YveSpacing.lg,
            YveSpacing.lg,
            YveSpacing.lg,
            100,
          ),
          itemCount: sessions.length,
          separatorBuilder: (_, __) => const SizedBox(height: YveSpacing.sm),
          itemBuilder: (BuildContext context, int i) {
            final StudySession s = sessions[i];
            return _SessionRow(
              session: s,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatScreen.resume(
                    sessionId: s.id,
                    sessionTitle: s.title,
                    subjectId: s.subjectId,
                    subjectName: s.subjectName,
                    subjectEmoji: s.subjectEmoji,
                    initialMode: s.mode,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, required this.onTap});
  final StudySession session;
  final VoidCallback onTap;

  String _relative() {
    final Duration diff = DateTime.now().difference(session.updatedAt);
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hours ago';
    if (diff.inDays == 1) return 'Yesterday';
    return '${diff.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Material(
      color: YveColors.surface,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: YveSpacing.cardRadius,
        child: Container(
          padding: const EdgeInsets.all(YveSpacing.md),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.cardRadius,
            boxShadow: YveSpacing.cardShadow,
            color: YveColors.surface,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: session.mode.tint,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(session.mode.icon,
                    color: session.mode.iconColor, size: 18),
              ),
              const SizedBox(width: YveSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(session.title, style: text.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      session.preview.isEmpty
                          ? '${session.mode.label} session'
                          : session.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _relative(),
                      style: const TextStyle(
                        fontSize: 11,
                        color: YveColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PracticeTab extends ConsumerWidget {
  const _PracticeTab({required this.subject});
  final Subject subject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<ConceptMastery>> conceptsAsync =
        ref.watch(conceptsBySubjectProvider(subject.id));
    return conceptsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object e, _) => _InlineError(message: e.toString()),
      data: (List<ConceptMastery> concepts) {
        if (concepts.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(YveSpacing.xl),
              child: Text(
                'No tracked concepts yet.\nThey appear here as you chat with Yve about this subject.',
                textAlign: TextAlign.center,
                style: TextStyle(color: YveColors.textSecondary),
              ),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            YveSpacing.lg,
            YveSpacing.lg,
            YveSpacing.lg,
            100,
          ),
          children: <Widget>[
            const _PracticeHeader(),
            const SizedBox(height: YveSpacing.md),
            for (final ConceptMastery c in concepts) ...<Widget>[
              _ConceptRow(
                mastery: c,
                onPractice: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ChatScreen(
                      subjectId: subject.id,
                      subjectName: subject.name,
                      subjectEmoji: subject.emoji,
                      initialMode: StudyMode.practice,
                      initialDraft: 'Quiz me on ${c.concept}',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: YveSpacing.sm),
            ],
          ],
        );
      },
    );
  }
}

class _PracticeHeader extends StatelessWidget {
  const _PracticeHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(YveSpacing.md),
      decoration: BoxDecoration(
        color: YveColors.primarySurface,
        borderRadius: YveSpacing.cardRadius,
      ),
      child: const Row(
        children: <Widget>[
          Icon(Icons.auto_awesome,
              size: 16, color: YveColors.primaryLight),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'These are the concepts Yve has seen you work on. Tap any to drill it in Practice mode.',
              style: TextStyle(
                fontSize: 12,
                color: YveColors.primary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConceptRow extends StatelessWidget {
  const _ConceptRow({required this.mastery, required this.onPractice});

  final ConceptMastery mastery;
  final VoidCallback onPractice;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: YveColors.surface,
      borderRadius: YveSpacing.cardRadius,
      child: InkWell(
        onTap: onPractice,
        borderRadius: YveSpacing.cardRadius,
        child: Container(
          padding: const EdgeInsets.all(YveSpacing.md),
          decoration: BoxDecoration(
            borderRadius: YveSpacing.cardRadius,
            boxShadow: YveSpacing.cardShadow,
            color: YveColors.surface,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: mastery.tint,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(mastery.icon,
                    color: mastery.foreground, size: 20),
              ),
              const SizedBox(width: YveSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      mastery.concept,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${mastery.confidenceLabel} · seen ${mastery.observations}× ',
                      style: TextStyle(
                        fontSize: 12,
                        color: mastery.foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.play_arrow_rounded,
                  color: YveColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}
