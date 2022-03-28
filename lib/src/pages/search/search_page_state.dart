import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/model/tab_bar_config.dart';

import '../../widget/loading_state_indicator.dart';

class SearchPageState {
  TabBarConfig tabBarConfig = TabBarConfig(name: '', searchConfig: SearchConfig());

  List<Gallery> gallerys = <Gallery>[];
  int nextPageNoToLoad = 0;
  int pageCount = -1;
  LoadingState loadingState = LoadingState.success;
}