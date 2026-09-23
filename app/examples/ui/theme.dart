import 'package:material_ui/material_ui.dart';
import 'package:flutterware_app/src/ui/side_menu.dart';
import 'package:flutterware_app/src/ui/theme.dart';

void main() => runApp(AppThemeDemo());

class AppThemeDemo extends StatelessWidget {
  const AppThemeDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: appTheme,
      home: DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            title: Text('Theme demo'),
            bottom: PreferredSize(
              preferredSize: Size.fromHeight(35),
              child: Stack(
                children: [
                  Positioned(
                    bottom: 0,
                    right: 0,
                    left: 0,
                    child: Container(
                      color: context.colors.tabDivider,
                      height: 1,
                    ),
                  ),
                  const TabBar(
                    tabs: [
                      Tab(text: 'Elements', height: 35),
                      Tab(text: 'Card', height: 35),
                      Tab(text: 'Menus', height: 35),
                    ],
                  ),
                ],
              ),
            ),
          ),
          body: TabBarView(children: [_Tab1(), _Tab2(), _Tab3()]),
        ),
      ),
    );
  }
}

class _Tab1 extends StatefulWidget {
  @override
  _Tab1State createState() => _Tab1State();
}

class _Tab1State extends State<_Tab1> {
  late TextEditingController _disabledText;
  bool _checkbox1 = true;
  bool _switch1 = false;
  bool _switch2 = true;

  @override
  void initState() {
    super.initState();

    _disabledText = TextEditingController(text: 'Disabled field');
  }

  @override
  void dispose() {
    _disabledText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    var textTheme = theme.textTheme;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      children: <Widget>[
        Wrap(
          spacing: 10,
          runSpacing: 20,
          children: [
            Text('Text'),
            ElevatedButton(onPressed: () {}, child: Text('Normal button')),
            ElevatedButton.icon(
              onPressed: () {},
              icon: Icon(Icons.access_alarm),
              label: Text('Icon button'),
            ),
            ElevatedButton(onPressed: null, child: Text('Disabled button')),
            OutlinedButton(onPressed: () {}, child: Text('Secondary button')),
            OutlinedButton(
              onPressed: null,
              child: Text('Secondary disabled button'),
            ),
            TextButton(onPressed: () {}, child: Text('Normal button')),
            IconButton(onPressed: () {}, icon: Icon(Icons.refresh)),
            PopupMenuButton(
              itemBuilder: (context) => [
                PopupMenuItem(child: Text('Reload')),
                PopupMenuItem(child: Text('Delete this item')),
              ],
            ),
            PopupMenuButton(
              itemBuilder: (context) => [
                PopupMenuItem(child: Text('Reload')),
                PopupMenuItem(child: Text('Delete this item')),
              ],
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('A menu', style: theme.textTheme.titleMedium),
                  Icon(Icons.expand_more),
                ],
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: context.colors.red,
              ),
              onPressed: () {},
              child: Text('Danger button'),
            ),
            SizedBox(
              width: 200,
              child: TextField(
                decoration: InputDecoration(
                  labelText: 'Normal text field',
                  helperText: 'Helper text',
                  hintText: 'Hint',
                ),
              ),
            ),
            SizedBox(
              width: 100,
              child: TextField(
                decoration: InputDecoration(
                  labelText: 'Text field',
                  errorText: 'With error',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  helperText: 'Helper text',
                  hintText: 'Hint',
                ),
              ),
            ),
            SizedBox(
              width: 100,
              child: TextField(controller: _disabledText, enabled: false),
            ),
            Checkbox(
              value: _checkbox1,
              onChanged: (_) {
                setState(() {
                  _checkbox1 = !_checkbox1;
                });
              },
            ),
            Checkbox(value: true, onChanged: null),
            Checkbox(value: false, onChanged: (_) {}),
            CircularProgressIndicator(),
            Switch(
              value: _switch1,
              onChanged: (v) {
                setState(() {
                  _switch1 = v;
                });
              },
            ),
            Switch.adaptive(
              value: _switch2,
              onChanged: (v) {
                setState(() {
                  _switch2 = v;
                });
              },
            ),
            DropdownButton<int>(
              items: [
                DropdownMenuItem(value: 0, child: Text('First value')),
                DropdownMenuItem(value: 1, child: Text('Second value')),
              ],
              value: 0,
              onChanged: (v) {},
            ),
            SizedBox(
              width: 200,
              child: DropdownButtonFormField<int>(
                items: [
                  DropdownMenuItem(value: 0, child: Text('First value')),
                  DropdownMenuItem(value: 1, child: Text('Second value')),
                ],
                initialValue: 0,
                onChanged: (v) {},
              ),
            ),
          ],
        ),
        for (var textSample in {
          'displayLarge': textTheme.displayLarge,
          'displayMedium': textTheme.displayMedium,
          'displaySmall': textTheme.displaySmall,
          'headlineLarge': textTheme.headlineLarge,
          'headlineMedium': textTheme.headlineMedium,
          'headlineSmall': textTheme.headlineSmall,
          'titleLarge': textTheme.titleLarge,
          'titleMedium': textTheme.titleMedium,
          'titleSmall': textTheme.titleSmall,
          'bodyLarge': textTheme.bodyLarge,
          'bodyMedium': textTheme.bodyMedium,
          'bodySmall': textTheme.bodySmall,
        }.entries)
          Text(
            '${textSample.key} (${textSample.value!.fontSize}, ${textSample.value!.fontWeight.toString().split('.').last})',
            style: textSample.value,
          ),
      ],
    );
  }
}

class _Tab2 extends StatelessWidget {
  const _Tab2();

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 30),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Text('My table', style: theme.textTheme.titleSmall),
        ),
        Card(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('A card', style: Theme.of(context).textTheme.titleLarge),
                DataTable(
                  columns: [
                    DataColumn(label: Text('First')),
                    DataColumn(label: Text('Second')),
                  ],
                  rows: [
                    for (var i = 0; i < 3; i++)
                      DataRow(
                        cells: [
                          DataCell(Text('1 + $i')),
                          DataCell(Text('2 + $i')),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Tab3 extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      scrollDirection: Axis.horizontal,
      children: [
        SideMenu(
          children: [
            SingleLineGroup(
              child: MenuLine(
                onTap: () {},
                isSelected: true,
                child: Row(
                  children: [
                    Icon(Icons.home, size: 18),
                    const SizedBox(width: 10),
                    Text('brewline'),
                  ],
                ),
              ),
            ),
            SingleLineGroup(
              child: MenuLine(
                onTap: () {},
                isSelected: false,
                child: Text('Icons'),
              ),
            ),
            CollapsibleMenu(title: Text('Pub dependencies'), children: []),
            CollapsibleMenu(title: Text('App tests'), children: []),
            CollapsibleMenu(title: Text('Icons'), children: []),
          ],
        ),
        const SizedBox(width: 20),
        SideMenu(
          children: [
            MenuLine(
              onTap: () {},
              isSelected: false,
              child: Row(
                children: [
                  Icon(Icons.home, size: 18),
                  const SizedBox(width: 10),
                  Text('brewline'),
                ],
              ),
            ),
            MenuLine(onTap: () {}, isSelected: true, child: Text('Icons')),
          ],
        ),
        const SizedBox(width: 20),
        SideMenu(
          children: [
            CollapsibleMenu(
              title: Text('App tests'),
              children: [
                Center(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 12),
                      minimumSize: Size(0, 30),
                    ),
                    onPressed: () {},
                    icon: Icon(Icons.play_arrow, size: 12),
                    label: Text('Start test runner'),
                  ),
                ),
                MenuLine(
                  onTap: () {},
                  isSelected: false,
                  indent: 1,
                  child: Text('Learn about App Test'),
                ),
                MenuLine(
                  onTap: () {},
                  isSelected: false,
                  indent: 1,
                  child: Text('Examples'),
                ),
                MenuLine(
                  onTap: () {},
                  isSelected: false,
                  expanded: false,
                  indent: 1,
                  child: Text('my_super_example.dart'),
                ),
                MenuLine(
                  onTap: () {},
                  isSelected: false,
                  expanded: true,
                  indent: 1,
                  child: Text('my_super_example.dart'),
                ),
                MenuLine(
                  onTap: () {},
                  isSelected: false,
                  indent: 2,
                  child: Text('Examples'),
                ),
              ],
            ),
            CollapsibleMenu(
              title: Text('App tests'),
              children: [
                MenuLine(
                  onTap: () {},
                  isSelected: false,
                  expanded: true,
                  indent: 1,
                  child: Text('my_super_example.dart'),
                ),
                MenuLine(
                  onTap: () {},
                  isSelected: false,
                  indent: 2,
                  child: Text(
                    'Onboarding should work correctly with all widgets',
                  ),
                ),
                MenuLine(
                  onTap: () {},
                  isSelected: false,
                  indent: 2,
                  child: Text('Login and logout should work'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
