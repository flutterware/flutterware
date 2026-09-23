import 'package:material_ui/material_ui.dart';

import 'knobs.dart';

class KnobsEditor extends StatelessWidget {
  final EditableKnobs knobs;

  const KnobsEditor(this.knobs, {super.key});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
        ),
        sliderTheme: SliderThemeData(
          showValueIndicator: ShowValueIndicator.onDrag,
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 50),
        children: [
          for (var knob in knobs.knobs.entries)
            _KnobLine(
              name: knob.key,
              editor: ListenableBuilder(
                listenable: knob.value,
                builder: (context, _) => _editorFor(knob.value),
              ),
            ),
        ],
      ),
    );
  }

  Widget _editorFor(Knob knob) {
    return switch (knob) {
      StringKnob() => _StringEditor(knob),
      BoolKnob() => _BoolEditor(knob),
      NumKnob<num>() => _NumEditor(knob),
      PickerKnob() => _PickerEditor(knob),
      DateTimeKnob() => _DateTimeEditor(knob),
      ActionButtonKnob() => _ButtonEditor(knob),
    };
  }
}

class _KnobLine extends StatelessWidget {
  final String name;
  final Widget editor;

  const _KnobLine({required this.name, required this.editor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              name,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: editor),
          ),
        ],
      ),
    );
  }
}

class _StringEditor extends StatefulWidget {
  final StringKnob knob;

  const _StringEditor(this.knob);

  @override
  State<_StringEditor> createState() => _StringEditorState();
}

class _StringEditorState extends State<_StringEditor> {
  final _globalKey = GlobalKey();
  late final _textController = TextEditingController(text: widget.knob.value);

  @override
  void initState() {
    super.initState();

    _textController.addListener(() {
      String? text = _textController.text;
      if (text.isEmpty) {
        text = null;
      }
      widget.knob.value = text;
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: _globalKey,
      controller: _textController,
      maxLines: null,
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.knob.defaultValue,
      ),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }
}

class _BoolEditor extends StatelessWidget {
  final BoolKnob knob;

  const _BoolEditor(this.knob);

  @override
  Widget build(BuildContext context) {
    return Checkbox(
      value: knob.value ?? knob.defaultValue,
      onChanged: (v) {
        knob.value = v;
      },
    );
  }
}

class _NumEditor extends StatelessWidget {
  final NumKnob knob;

  const _NumEditor(this.knob);

  @override
  Widget build(BuildContext context) {
    if (knob.min != null && knob.max != null) {
      return Slider(
        label: knob.requiredValue.toString(),
        value: knob.requiredValue.toDouble(),
        min: knob.min!.toDouble(),
        max: knob.max!.toDouble(),
        onChanged: (v) {
          var value = knob.isInt ? v.toInt() : v;
          knob.value = value;
        },
      );
    } else {
      return TextFormField(
        decoration: InputDecoration(
          hintText: knob.defaultValue.toString(),
          isDense: true,
        ),
        initialValue: knob.value?.toString() ?? knob.defaultValue.toString(),
        onChanged: (e) {
          var value = knob.isInt ? int.tryParse(e) : double.tryParse(e);
          knob.value = value;
        },
      );
    }
  }
}

class _PickerEditor<T> extends StatelessWidget {
  final PickerKnob knob;

  const _PickerEditor(this.knob, {super.key});

  @override
  Widget build(BuildContext context) {
    return DropdownButton(
      value: knob.requiredValue,
      items: [
        for (var v in knob.options.entries)
          DropdownMenuItem(
            value: v.value,
            child: pickerOptionWidget(knob, v.key, v.value),
          ),
      ],
      onChanged: (v) {
        knob.value = v;
      },
    );
  }
}

class _DateTimeEditor extends StatelessWidget {
  final DateTimeKnob knob;

  const _DateTimeEditor(this.knob);

  @override
  Widget build(BuildContext context) {
    var value = knob.requiredValue;

    String pad(int value) => '$value'.padLeft(2, '0');

    String formatted;
    if (value == null) {
      formatted = '<null>';
    } else {
      formatted = '${value.year}-${pad(value.month)}-${pad(value.day)}';
      if (!knob.dateOnly) {
        formatted += ' ${pad(value.hour)}:${pad(value.minute)}';
      }
    }

    return Row(
      children: [
        TextButton(
          onPressed: () async {
            var previousValue = value;
            var pickedDate = await showDatePicker(
              context: context,
              firstDate: DateTime(0),
              lastDate: DateTime(2100),
              initialDate: value,
            );
            if (pickedDate != null) {
              var pickedTime = TimeOfDay(hour: 0, minute: 0);
              if (!knob.dateOnly && context.mounted) {
                pickedTime =
                    await showTimePicker(
                      context: context,
                      initialTime: value != null
                          ? TimeOfDay(hour: value.hour, minute: value.minute)
                          : pickedTime,
                    ) ??
                    pickedTime;
              }
              var newValue = knob.value = pickedDate.copyWith(
                hour: pickedTime.hour,
                minute: pickedTime.minute,
              );

              if (previousValue != null && previousValue.isUtc) {
                switchUtc(true, newValue);
              }
            }
          },
          child: Text(formatted),
        ),
        if (knob.isNullable && value != null)
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: Size.zero),
              onPressed: () {
                knob.value = null;
              },
              child: Text('Clear'),
            ),
          ),
        if (value != null)
          InkWell(
            onTap: () {
              switchUtc(!value.isUtc, value);
            },
            child: Row(
              children: [
                Checkbox(
                  value: value.isUtc,
                  onChanged: (v) => switchUtc(v!, value),
                ),
                Text('utc'),
              ],
            ),
          ),
      ],
    );
  }

  void switchUtc(bool isUtc, DateTime value) {
    knob.value = isUtc
        ? DateTime.utc(
            value.year,
            value.month,
            value.day,
            value.hour,
            value.minute,
          )
        : DateTime(
            value.year,
            value.month,
            value.day,
            value.hour,
            value.minute,
          );
  }
}

class _ButtonEditor<T> extends StatelessWidget {
  final ActionButtonKnob knob;

  const _ButtonEditor(this.knob);

  @override
  Widget build(BuildContext context) {
    return FilledButton(onPressed: knob.onPressed, child: Text(knob.text));
  }
}
