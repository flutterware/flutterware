import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants.dart';
import '../ui/action_button.dart';
import '../ui/panel_header.dart';
import '../ui/theme.dart';

/// The about screen's root, so a test can scope to it.
const aboutScreenKey = Key('about-screen');

/// Where to write about flutterware. The README and the site link the same
/// address.
const contactEmail = 'hello@flutterware.dev';

const siteUrl = 'https://flutterware.dev';
const repositoryUrl = 'https://github.com/flutterware/flutterware';
const pubUrl = 'https://pub.dev/packages/flutterware';

/// `fw:///worktrees/<worktree>/about` — flutterware itself.
///
/// The one shell screen that is not about the checkout (see
/// [Address.shellAbout]): which version this is, where it lives, and how to
/// get in touch. It reads nothing, so it draws the same for every worktree
/// and for one that is not open.
///
/// Small on purpose: a few lines and a row of links, none of them louder than
/// the others. An about screen that sells is the wrong register for a tool
/// you are already inside.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    var type = context.type;
    return ListView(
      key: aboutScreenKey,
      padding: const EdgeInsets.only(bottom: FwSpacing.xxxl),
      children: [
        FwPanelHeader(
          'About flutterware',
          subtitle: ['version $flutterwareVersion', 'MIT license'],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            panelGutter,
            FwSpacing.xl,
            panelGutter,
            0,
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'If you use flutterware, are trying it out, or wonder '
                    "whether it would fit your project, we'd love to hear "
                    'from you. Questions, ideas, or something that got in '
                    'your way: write to us.',
                    style: type.body,
                  ),
                  const Gap(FwSpacing.xl),
                  Wrap(
                    spacing: FwSpacing.md,
                    runSpacing: FwSpacing.md,
                    children: [
                      _Link(
                        contactEmail,
                        Uri(scheme: 'mailto', path: contactEmail),
                        icon: Icons.mail_outline,
                      ),
                      _Link('flutterware.dev', Uri.parse(siteUrl)),
                      _Link('GitHub', Uri.parse(repositoryUrl)),
                      _Link('pub.dev', Uri.parse(pubUrl)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A button that opens a place outside the studio: the mail client, the
/// browser. It has no outcome to acknowledge, so it does not.
class _Link extends StatelessWidget {
  const _Link(this.label, this.uri, {this.icon = Icons.open_in_new});

  final String label;
  final Uri uri;
  final IconData icon;

  @override
  Widget build(BuildContext context) => FwActionButton(
    label: label,
    icon: icon,
    acknowledges: false,
    onPressed: () async {
      await launchUrl(uri);
    },
  );
}
