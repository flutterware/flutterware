import 'package:material_ui/material_ui.dart';

import '../../../utils/ellipisis.dart';
import '../../devbar.dart';
import '../../utils/auto_scroll_to_bottom.dart';
import '../../utils/json_viewer.dart';
import 'plugin.dart';

class NetworkList extends StatelessWidget {
  final LogNetworkPlugin service;
  const NetworkList(this.service, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        Row(
          children: [
            SizedBox(width: 15),
            Text('Options:'),
            TextButton(
              onPressed: () {
                service.clear();
              },
              child: Text('Clear'),
            ),
          ],
        ),
        Expanded(
          child: AutoScroller<List<NetworkRequest>>(
            stream: service.requests,
            builder: (context, controller, data) {
              return ListView.separated(
                controller: controller,
                padding: EdgeInsets.symmetric(vertical: 20),
                separatorBuilder: (context, _) => SizedBox(height: 1),
                itemCount: data.length,
                itemBuilder: (context, index) {
                  var request = data[index];
                  return RequestTile(request);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class RequestTile extends StatelessWidget {
  final NetworkRequest request;

  const RequestTile(this.request, {super.key});

  @override
  Widget build(BuildContext context) {
    var devbar = DevbarState.of(context);

    return ListTile(
      dense: true,
      title: Text(
        '${request.httpMethod.toUpperCase()} ${[if (request.apiName != null) request.apiName, request.path].join('/')}',
      ),
      leading: Text(request.errorResponse != null ? 'FAIL' : 'OK'),
      subtitle: request.parameters.isNotEmpty ? Text(_parametersText) : null,
      trailing: switch (request.watch) {
        null => null,
        var watch when watch.isRunning => CircularProgressIndicator(),
        var watch => Text('${watch.elapsedMilliseconds}ms'),
      },
      onTap: () {
        devbar.ui.showOverlayDialog(
          builder: (context) => RequestDialog(request),
        );
      },
    );
  }

  String get _parametersText {
    return request.parameters.entries
        .map((e) => '${e.key}: ${ellipsisCenter(e.value ?? '', maxLength: 30)}')
        .join(', ');
  }
}

class RequestDialog extends StatelessWidget {
  final NetworkRequest request;

  const RequestDialog(this.request, {super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: EdgeInsets.zero,
      content: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            bottom: TabBar(
              tabs: [
                Tab(text: 'Request'),
                Tab(text: request.errorResponse != null ? 'Error' : 'Response'),
              ],
            ),
            title: Text(
              '${request.httpMethod.toUpperCase()} ${request.path}',
              style: TextStyle(fontSize: 12),
            ),
          ),
          body: TabBarView(
            children: [
              _RequestTab(request),
              request.errorResponse != null
                  ? _ErrorTab(request.errorResponse!)
                  : _ResponseTab(request),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            Navigator.pop(context);
          },
          child: Text('OK'),
        ),
      ],
    );
  }
}

class _RequestTab extends StatelessWidget {
  final NetworkRequest request;

  const _RequestTab(this.request);

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        ListTile(
          dense: true,
          title: Text(request.httpMethod.toUpperCase()),
          subtitle: Text(request.path),
        ),
        if (request.parameters.isNotEmpty)
          ListTile(
            dense: true,
            title: Text('Parameters:'),
            subtitle: JsonViewer(request.parameters),
          ),
        if (request.requestBody != null)
          ListTile(
            dense: true,
            title: Text('body:'),
            subtitle: JsonViewer(request.requestBody),
          ),
      ],
    );
  }
}

class _ResponseTab extends StatelessWidget {
  final NetworkRequest request;

  const _ResponseTab(this.request);

  @override
  Widget build(BuildContext context) {
    if (request.response == null) {
      return Center(child: Text('<empty>'));
    }

    // Text as text. Handing a String to the viewer JSON-encodes it, so a body
    // that is not JSON — a stack, an HTML error page, `<unknown>` — came back
    // as one escaped line with quotes around it.
    if (request.response case String text) {
      return SingleChildScrollView(
        padding: EdgeInsets.all(10),
        child: SelectableText(text),
      );
    }

    return JsonViewer(request.response);
  }
}

class _ErrorTab extends StatelessWidget {
  final ErrorResponse response;

  const _ErrorTab(this.response);

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        ListTile(
          dense: true,
          title: Text('${response.reason} (${response.code})'),
          subtitle: Text(response.message),
        ),
      ],
    );
  }
}
