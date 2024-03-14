import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:io' as io;

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:executor/executor.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_instance/src/extension_instance.dart';
import 'package:get/get_rx/src/rx_types/rx_types.dart';
import 'package:get/get_state_manager/src/simple/get_controllers.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/database/dao/gallery_dao.dart';
import 'package:jhentai/src/database/dao/gallery_group_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/exception/eh_parse_exception.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/extension/list_extension.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/service/super_resolution_service.dart';
import 'package:jhentai/src/setting/download_setting.dart';
import 'package:jhentai/src/setting/site_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/speed_computer.dart';
import 'package:jhentai/src/utils/log.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:path/path.dart' as path;
import 'package:path/path.dart';
import 'package:retry/retry.dart';
import 'package:drift/drift.dart';

import '../database/dao/gallery_image_dao.dart';
import '../exception/cancel_exception.dart';
import '../exception/eh_site_exception.dart';
import '../model/gallery_detail.dart';
import '../model/gallery_image.dart';
import '../network/eh_request.dart';
import '../pages/download/grid/mixin/grid_download_page_service_mixin.dart';
import '../setting/path_setting.dart';
import '../utils/eh_executor.dart';
import '../utils/eh_spider_parser.dart';
import '../utils/snack_util.dart';

/// Responsible for local images meta-data and download all images of a gallery
class GalleryDownloadService extends GetxController with GridBasePageServiceMixin {
  final String downloadImageId = 'downloadImageId';
  final String downloadImageUrlId = 'downloadImageUrlId';
  final String galleryDownloadProgressId = 'galleryDownloadProgressId';
  final String galleryDownloadSpeedComputerId = 'galleryDownloadSpeedComputerId';
  final String galleryDownloadSuccessId = 'galleryDownloadSuccessId';

  late EHExecutor executor;

  List<String> allGroups = [];
  List<GalleryDownloadedData> gallerys = [];
  Map<int, GalleryDownloadInfo> galleryDownloadInfos = {};

  List<GalleryDownloadedData> gallerysWithGroup(String group) => gallerys.where((g) => galleryDownloadInfos[g.gid]!.group == group).toList();

  static const int _maxRetryTimes = 3;
  static const String metadataFileName = 'metadata';
  static const int _maxTitleLength = 85;

  static const int defaultDownloadGalleryPriority = 4;
  static const int _priorityBase = 100000000;

  final Completer<bool> _completer = Completer();

  Future<bool> get completed => _completer.future;

  static void init() {
    Get.put(GalleryDownloadService(), permanent: true);
  }

  @override
  Future<void> onInit() async {
    await _instantiateFromDB();

    Log.debug('init DownloadService success, download task count: ${gallerys.length}');

    _startExecutor();

    _completer.complete(true);

    if (DownloadSetting.restoreTasksAutomatically.isTrue) {
      await restoreTasks();
    }

    super.onInit();
  }

  bool containGallery(int gid) => galleryDownloadInfos.containsKey(gid);

  Future<void> downloadGallery(GalleryDownloadedData gallery, {bool resume = false}) async {
    if (!resume && galleryDownloadInfos.containsKey(gallery.gid)) {
      return;
    }

    _ensureDownloadDirExists();

    /// If it's a new download task, record info.
    if (!resume && !await _initGalleryInfo(gallery)) {
      return;
    }

    galleryDownloadInfos[gallery.gid]!.speedComputer.start();

    Log.info('Begin to download gallery: ${gallery.title}, original: ${gallery.downloadOriginalImage}');

    _submitTask(
      gid: gallery.gid,
      priority: _computeGalleryTaskPriority(gallery),
      task: _downloadGalleryTask(gallery),
    );
  }

  Future<void> pauseAllDownloadGallery() async {
    await Future.wait(gallerys.map(pauseDownloadGallery).toList());
  }

  Future<void> pauseDownloadGalleryByGid(int gid) async {
    GalleryDownloadedData? gallery = gallerys.firstWhereOrNull((gallery) => gallery.gid == gid);
    if (gallery != null) {
      return pauseDownloadGallery(gallery);
    }
  }

  Future<void> pauseDownloadGallery(GalleryDownloadedData gallery) async {
    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;
    GalleryDownloadProgress downloadProgress = galleryDownloadInfo.downloadProgress;

    if (downloadProgress.downloadStatus != DownloadStatus.downloading) {
      return;
    }

    if (!await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(gid: Value(gallery.gid), downloadStatusIndex: Value(DownloadStatus.paused.index)),
    )) {
      return;
    }

    downloadProgress.downloadStatus = DownloadStatus.paused;
    update(['$galleryDownloadProgressId::${gallery.gid}']);

    for (AsyncTask task in galleryDownloadInfo.tasks) {
      executor.cancelTask(task);
    }

    galleryDownloadInfo.tasks.clear();
    galleryDownloadInfo.cancelToken.cancel();
    galleryDownloadInfo.speedComputer.pause();

    for (GalleryImage? image in galleryDownloadInfo.images) {
      /// no need to update db
      if (image?.downloadStatus == DownloadStatus.downloading) {
        image?.downloadStatus = DownloadStatus.paused;
        update(['$downloadImageId::${gallery.gid}']);
      }
    }

    _saveGalleryInfoInDisk(gallery);

    Log.info('Pause download gallery: ${gallery.title}');
  }

  Future<void> resumeAllDownloadGallery() async {
    await Future.wait(gallerys.map(resumeDownloadGallery).toList());
  }

  Future<void> resumeDownloadGalleryByGid(int gid) async {
    GalleryDownloadedData? gallery = gallerys.firstWhereOrNull((gallery) => gallery.gid == gid);
    if (gallery != null) {
      return resumeDownloadGallery(gallery);
    }
  }

  Future<void> resumeDownloadGallery(GalleryDownloadedData gallery) async {
    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;
    GalleryDownloadProgress downloadProgress = galleryDownloadInfo.downloadProgress;

    if (downloadProgress.downloadStatus != DownloadStatus.paused) {
      return;
    }

    if (!await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(gid: Value(gallery.gid), downloadStatusIndex: Value(DownloadStatus.downloading.index)),
    )) {
      return;
    }

    downloadProgress.downloadStatus = DownloadStatus.downloading;
    update(['$galleryDownloadProgressId::${gallery.gid}']);

    /// can't reuse
    galleryDownloadInfo.cancelToken = CancelToken();
    galleryDownloadInfo.speedComputer.start();

    for (GalleryImage? image in galleryDownloadInfo.images) {
      /// no need to update db
      if (image?.downloadStatus == DownloadStatus.paused) {
        image?.downloadStatus = DownloadStatus.downloading;
        update(['$downloadImageId::${gallery.gid}']);
      }
    }

    Log.info('Resume download gallery: ${gallery.title}');

    _saveGalleryInfoInDisk(gallery);

    downloadGallery(gallery, resume: true);
  }

  Future<void> deleteGalleryByGid(int gid) async {
    GalleryDownloadedData? gallery = gallerys.firstWhereOrNull((gallery) => gallery.gid == gid);
    if (gallery != null) {
      return deleteGallery(gallery);
    }
  }

  Future<void> deleteGallery(GalleryDownloadedData gallery, {bool deleteImages = true}) async {
    await pauseDownloadGallery(gallery);

    Log.info('Delete download gallery: ${gallery.title}, deleteImages:$deleteImages');

    await Get.find<SuperResolutionService>().deleteSuperResolve(gallery.gid, SuperResolutionType.gallery);

    await _clearGalleryDownloadInfoInDatabase(gallery.gid);
    if (deleteImages) {
      _clearDownloadedImageInDisk(gallery);
    }
    _clearGalleryInfoInMemory(gallery);
  }

  /// Update local downloaded gallery if there's a new version.
  Future<void> updateGallery(GalleryDownloadedData oldGallery, GalleryUrl newVersionGalleryUrl) async {
    Log.info('update gallery: ${oldGallery.title}');

    GalleryDetail newGalleryDetail;
    try {
      ({GalleryDetail galleryDetails, String apikey}) detailPageInfo = await retry(
        () => EHRequest.requestDetailPage(galleryUrl: newVersionGalleryUrl.url, parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey),
        retryIf: (e) => e is DioException,
        maxAttempts: _maxRetryTimes,
      );
      newGalleryDetail = detailPageInfo.galleryDetails;
    } on DioException catch (e) {
      Log.info('${'updateGalleryError'.tr}, reason: ${e.errorMsg}');
      snack('updateGalleryError'.tr, e.errorMsg ?? '', longDuration: true);
      return;
    } on EHSiteException catch (e) {
      Log.info('${'updateGalleryError'.tr}, reason: ${e.message}');
      snack('updateGalleryError'.tr, e.message, longDuration: true);
      pauseAllDownloadGallery();
      return;
    }

    GalleryDownloadedData newGallery = GalleryDownloadedData(
      gid: newGalleryDetail.galleryUrl.gid,
      token: newGalleryDetail.galleryUrl.token,
      title: newGalleryDetail.japaneseTitle ?? newGalleryDetail.rawTitle,
      category: newGalleryDetail.category,
      pageCount: newGalleryDetail.pageCount,
      oldVersionGalleryUrl: oldGallery.galleryUrl,
      galleryUrl: newGalleryDetail.galleryUrl.url,
      uploader: newGalleryDetail.uploader,
      publishTime: newGalleryDetail.publishTime,
      downloadStatusIndex: DownloadStatus.downloading.index,
      insertTime: DateTime.now().toString(),
      downloadOriginalImage: oldGallery.downloadOriginalImage,
      priority: GalleryDownloadService.defaultDownloadGalleryPriority,
      sortOrder: 0,
      groupName: galleryDownloadInfos[oldGallery.gid]!.group,
    );

    downloadGallery(newGallery);
  }

  Future<void> reDownloadGalleryByGid(int gid) async {
    GalleryDownloadedData? gallery = gallerys.firstWhereOrNull((gallery) => gallery.gid == gid);
    if (gallery != null) {
      return reDownloadGallery(gallery);
    }
  }

  Future<void> reDownloadGallery(GalleryDownloadedData gallery) async {
    Log.info('Re-download gallery: ${gallery.gid}');

    await deleteGallery(gallery);

    downloadGallery(gallery);
  }

  Future<void> reDownloadImage(int gid, int serialNo) async {
    GalleryDownloadedData? gallery = gallerys.singleWhereOrNull((g) => g.gid == gid);
    GalleryDownloadInfo? galleryDownloadInfo = galleryDownloadInfos[gid];
    GalleryImage? image = galleryDownloadInfo?.images[serialNo];

    if (gallery == null || galleryDownloadInfo == null || image == null) {
      return;
    }

    Log.info('Re-download image, gid: $gid, index: $serialNo');

    if (galleryDownloadInfo.downloadProgress.hasDownloaded[serialNo] == true) {
      galleryDownloadInfo.downloadProgress.curCount--;
    }
    galleryDownloadInfo.downloadProgress.hasDownloaded[serialNo] = false;
    galleryDownloadInfo.speedComputer.resetProgress(serialNo);
    galleryDownloadInfo.speedComputer.start();
    await _updateImageStatus(gallery, image, serialNo, DownloadStatus.downloading);
    await _updateGalleryDownloadStatus(gallery, DownloadStatus.downloading);
    _deleteImageInDisk(image);

    update(['$galleryDownloadSuccessId::${gallery.gid}', '$galleryDownloadProgressId::${gallery.gid}']);

    _reParseImageUrlAndDownload(gallery, serialNo);
  }

  Future<void> assignPriority(GalleryDownloadedData gallery, int priority) async {
    if (priority == galleryDownloadInfos[gallery.gid]?.priority) {
      return;
    }

    Log.info('Assign priority, gid: ${gallery.gid}, priority: $priority');

    if (!await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(gid: Value(gallery.gid), priority: Value(priority)),
    )) {
      return;
    }

    galleryDownloadInfos[gallery.gid]!.priority = priority;

    if (galleryDownloadInfos[gallery.gid]?.downloadProgress.downloadStatus == DownloadStatus.downloading) {
      await pauseDownloadGallery(gallery);
      await resumeDownloadGallery(gallery);
    }
  }

  Future<bool> updateGroupByGid(int gid, String group) async {
    GalleryDownloadedData? gallery = gallerys.firstWhereOrNull((gallery) => gallery.gid == gid);
    if (gallery != null) {
      return updateGroup(gallery, group);
    }
    return false;
  }

  Future<bool> updateGroup(GalleryDownloadedData gallery, String group) async {
    galleryDownloadInfos[gallery.gid]?.group = group;

    if (!allGroups.contains(group) && !await _addGroup(group)) {
      return false;
    }

    _sortGallerys();

    return await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(gid: Value(gallery.gid), groupName: Value(group)),
    );
  }

  Future<void> renameGroup(String oldGroup, String newGroup) async {
    List<GalleryDownloadedData> galleryDownloadedDatas = gallerys.where((g) => galleryDownloadInfos[g.gid]!.group == oldGroup).toList();

    await appDb.transaction(() async {
      if (!allGroups.contains(newGroup) && !await _addGroup(newGroup)) {
        return;
      }

      for (GalleryDownloadedData g in galleryDownloadedDatas) {
        galleryDownloadInfos[g.gid]!.group = newGroup;
        await _updateGalleryInDatabase(
          GalleryDownloadedCompanion(gid: Value(g.gid), groupName: Value(newGroup)),
        );
      }

      await _deleteGroup(oldGroup);
    });

    _sortGallerys();
  }

  Future<void> deleteGroup(String group) {
    return _deleteGroup(group);
  }

  Future<void> updateGalleryOrder(List<GalleryDownloadedData> gallerys) async {
    await appDb.transaction(() async {
      for (GalleryDownloadedData gallery in gallerys) {
        await _updateGalleryInDatabase(
          GalleryDownloadedCompanion(gid: Value(gallery.gid), sortOrder: Value(galleryDownloadInfos[gallery.gid]!.sortOrder)),
        );
      }
    });

    _sortGallerys();
  }

  Future<void> updateGroupOrder(int beforeIndex, int afterIndex) async {
    if (afterIndex == allGroups.length - 1) {
      allGroups.add(allGroups.removeAt(beforeIndex));
    } else {
      allGroups.insert(afterIndex, allGroups.removeAt(beforeIndex));
    }

    Log.info('Update group order: $allGroups');

    await appDb.transaction(() async {
      for (int i = 0; i < allGroups.length; i++) {
        await GalleryGroupDao.updateGalleryGroupOrder(allGroups[i], i);
      }
    });
  }

  /// Use metadata in each gallery folder to restore download status, then sync to database.
  /// This is used after re-install app, or share download folder to another user.
  Future<int> restoreTasks() async {
    await completed;

    io.Directory downloadDir = io.Directory(DownloadSetting.downloadPath.value);
    if (!downloadDir.existsSync()) {
      return 0;
    }

    int restoredCount = 0;
    for (io.FileSystemEntity galleryDir in downloadDir.listSync()) {
      io.File metadataFile = io.File(path.join(galleryDir.path, metadataFileName));

      /// metadata file does not exist
      if (!metadataFile.existsSync()) {
        continue;
      }

      Map metadata = jsonDecode(metadataFile.readAsStringSync());

      /// compatible with new field
      (metadata['gallery'] as Map).putIfAbsent('downloadOriginalImage', () => false);
      (metadata['gallery'] as Map).putIfAbsent('sortOrder', () => 0);
      if ((metadata['gallery'] as Map)['insertTime'] == null) {
        (metadata['gallery'] as Map)['insertTime'] = DateTime.now().toString();
      }
      if ((metadata['gallery'] as Map)['priority'] == null) {
        (metadata['gallery'] as Map)['priority'] = defaultDownloadGalleryPriority;
      }
      if ((metadata['gallery'] as Map)['groupName'] == null) {
        (metadata['gallery'] as Map)['groupName'] = 'default'.tr;
      }

      GalleryDownloadedData gallery = GalleryDownloadedData.fromJson(metadata['gallery']);
      List<GalleryImage?> images = (jsonDecode(metadata['images']) as List).map((_map) => _map == null ? null : GalleryImage.fromJson(_map)).toList();

      /// skip if exists
      if (galleryDownloadInfos.containsKey(gallery.gid)) {
        continue;
      }

      /// To deal with changed download location, compute download path again.
      for (int serialNo = 0; serialNo < images.length; serialNo++) {
        if (images[serialNo] == null) {
          continue;
        }
        images[serialNo]!.path = _computeImageDownloadRelativePath(gallery.title, gallery.gid, images[serialNo]!.url, serialNo);
      }

      /// For some reason, downloaded status is not updated correctly, check it again
      if (gallery.downloadStatusIndex != DownloadStatus.downloaded.index) {
        int downloadedImageCount = images.fold(0, (total, image) => total + (image?.downloadStatus == DownloadStatus.downloaded ? 1 : 0));
        if (downloadedImageCount == gallery.pageCount) {
          gallery = gallery.copyWith(downloadStatusIndex: DownloadStatus.downloaded.index);
        }
      }

      if (!await _restoreInfoInDatabase(gallery, images)) {
        Log.error('Restore download failed. Gallery: ${gallery.title}');
        _clearGalleryDownloadInfoInDatabase(gallery.gid);
        continue;
      }

      _initGalleryInfoInMemory(gallery, images: images, sort: false);

      restoredCount++;
    }

    if (restoredCount > 0) {
      _sortGallerys();
    }

    return restoredCount;
  }

  Future<void> updateImagePathAfterDownloadPathChanged() async {
    await appDb.transaction(() async {
      for (GalleryDownloadedData gallery in gallerys) {
        List<GalleryImage?> images = galleryDownloadInfos[gallery.gid]!.images;

        for (int serialNo = 0; serialNo < images.length; serialNo++) {
          if (images[serialNo] == null) {
            continue;
          }

          String newPath = _computeImageDownloadRelativePath(gallery.title, gallery.gid, images[serialNo]!.url, serialNo);

          if (await _updateImageInDatabase(
            ImageCompanion(gid: Value(gallery.gid), serialNo: Value(serialNo), path: Value(newPath)),
          )) {
            Log.error('Update image path after download path changed failed');
          }
          images[serialNo]!.path = newPath;

          update(['$downloadImageId::${gallery.gid}::$serialNo', '$downloadImageUrlId::${gallery.gid}::$serialNo']);
        }
      }
    });
  }

  void updateExecutor() {
    executor.concurrency = DownloadSetting.downloadTaskConcurrency.value;
    executor.rate = Rate(DownloadSetting.maximum.value, DownloadSetting.period.value);
  }

  /// start executor
  void _startExecutor() {
    Log.debug('start download executor');

    executor = EHExecutor(
      concurrency: DownloadSetting.downloadTaskConcurrency.value,
      rate: Rate(DownloadSetting.maximum.value, DownloadSetting.period.value),
    );

    /// Resume gallery whose status is [downloading], order by insertTime
    for (GalleryDownloadedData g in gallerys) {
      if (g.downloadStatusIndex == DownloadStatus.downloading.index) {
        // gid2SpeedComputer[g.gid]!.start();
        downloadGallery(g, resume: true);
      }
    }
  }

  /// shutdown executor
  Future<void> _shutdownExecutor() async {
    Log.info('Shutdown download executor');

    await pauseAllDownloadGallery();
    executor.close();
  }

  void _submitTask({
    required int gid,
    required int priority,
    required AsyncTask<void> task,
  }) {
    galleryDownloadInfos[gid]?.tasks.add(task);

    executor.scheduleTask(priority, task).then((_) => galleryDownloadInfos[gid]?.tasks.remove(task)).onError((e, stackTrace) {
      galleryDownloadInfos[gid]?.tasks.remove(task);
      if (e is! CancelException) {
        Log.error('Executor exception!', e, stackTrace);
        Log.uploadError(e);
      }
    });
  }

  /// Rules:
  /// 1. If [downloadAllGallerysOfSamePriority] is false
  ///   1.1 Galleries download order:
  ///     1.1.1 gallery with high priority
  ///     1.1.2 gallery with low priority
  ///     1.1.3 if priority is same, download only 1 gallery simultaneously in the order of insert time ASC
  ///   1.2 For each gallery, previous image should be downloaded earlier
  /// 2. If [downloadAllGallerysOfSamePriority] is true
  ///   2.1 Galleries download order:
  ///     2.1.1 gallery with high priority
  ///     2.1.2 gallery with low priority
  ///     2.1.3 if priority is same, download all gallerys simultaneously
  ///   2.2 For each gallery, previous image should be downloaded earlier and images with same [serialNo] has the same priority no matter which gallery they belong to
  ///
  /// Because a gallery has most 2000 images, we assign 2000 numbers to each gallery
  int _computeGalleryTaskPriority(GalleryDownloadedData gallery) {
    if (_taskHasBeenPausedOrRemoved(gallery)) {
      return 0;
    }

    int groupPriority = galleryDownloadInfos[gallery.gid]!.priority * _priorityBase;

    if (DownloadSetting.downloadAllGallerysOfSamePriority.isTrue) {
      return groupPriority;
    }

    /// priority is same, order by insert time
    DateTime insertTime = DateFormat('yyyy-MM-dd HH:mm:ss').parse(gallery.insertTime);
    int timePriority = int.parse(DateFormat('MMddHHmmss').format(insertTime)) * 2000;

    return groupPriority + timePriority;
  }

  int _computeImageTaskPriority(GalleryDownloadedData gallery, int serialNo) {
    return _computeGalleryTaskPriority(gallery) + serialNo;
  }

  String _computeGalleryTitle(String rawTitle) {
    String title = rawTitle.replaceAll(RegExp(r'[/|?,:*"<>\\.]'), ' ').trim();

    if (title.length > _maxTitleLength) {
      title = title.substring(0, _maxTitleLength).trim();
    }

    return title;
  }

  String computeGalleryDownloadPath(String rawTitle, int gid) {
    String title = _computeGalleryTitle(rawTitle);
    return path.join(DownloadSetting.downloadPath.value, '$gid - $title');
  }

  String _computeImageDownloadAbsolutePath(String title, int gid, String imageUrl, int serialNo) {
    /// original image's url doesn't has an ext
    String? ext = imageUrl.contains('fullimg.php') ? 'jpg' : imageUrl.split('.').last;

    return path.join(
      computeGalleryDownloadPath(title, gid),
      '$serialNo.$ext',
    );
  }

  String _computeImageDownloadRelativePath(String title, int gid, String imageUrl, int serialNo) {
    return path.relative(
      _computeImageDownloadAbsolutePath(title, gid, imageUrl, serialNo),
      from: PathSetting.getVisibleDir().path,
    );
  }

  static String computeImageDownloadAbsolutePathFromRelativePath(String imageRelativePath) {
    String path = join(PathSetting.getVisibleDir().path, imageRelativePath);

    /// I don't know why some images can't be loaded on Windows... If you knows, please tell me
    if (!GetPlatform.isWindows) {
      return path;
    }

    return join(rootPrefix(path), relative(path, from: rootPrefix(path)));
  }

  void _sortGallerys() {
    gallerys.sort((a, b) {
      GalleryDownloadInfo? aInfo = galleryDownloadInfos[a.gid];
      GalleryDownloadInfo? bInfo = galleryDownloadInfos[b.gid];
      if (aInfo == null || bInfo == null) {
        return 0;
      }

      if (!(aInfo.group == 'default'.tr && bInfo.group == 'default'.tr)) {
        if (aInfo.group == 'default'.tr) {
          return 1;
        }
        if (bInfo.group == 'default'.tr) {
          return -1;
        }
      }

      int gResult = aInfo.group.compareTo(bInfo.group);
      if (gResult != 0) {
        return gResult;
      }

      int aOrder = galleryDownloadInfos[a.gid]!.sortOrder;
      int bOrder = galleryDownloadInfos[b.gid]!.sortOrder;
      if (aOrder - bOrder != 0) {
        return aOrder - bOrder;
      }

      DateTime aTime = DateFormat('yyyy-MM-dd HH:mm:ss').parse(a.insertTime);
      DateTime bTime = DateFormat('yyyy-MM-dd HH:mm:ss').parse(b.insertTime);

      return bTime.difference(aTime).inMilliseconds;
    });
  }

  bool _taskHasBeenPausedOrRemoved(GalleryDownloadedData gallery) {
    return galleryDownloadInfos[gallery.gid] == null || galleryDownloadInfos[gallery.gid]!.downloadProgress.downloadStatus == DownloadStatus.paused;
  }

  // Task

  AsyncTask<void> _downloadGalleryTask(GalleryDownloadedData gallery) {
    return () {
      if (_taskHasBeenPausedOrRemoved(gallery)) {
        return;
      }

      for (int serialNo = 0; serialNo < gallery.pageCount; serialNo++) {
        _processImage(gallery, serialNo);
      }
    };
  }

  Future<void> _processImage(GalleryDownloadedData gallery, int serialNo) async {
    if (_taskHasBeenPausedOrRemoved(gallery)) {
      return;
    }

    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;

    /// has downloaded this image => nothing to do
    if (galleryDownloadInfo.images[serialNo]?.downloadStatus == DownloadStatus.downloaded) {
      return;
    }

    /// url has been parsed => download directly
    if (galleryDownloadInfo.images[serialNo]?.url != null) {
      return _submitTask(
        gid: gallery.gid,
        priority: _computeImageTaskPriority(gallery, serialNo),
        task: _downloadImageTask(gallery, serialNo),
      );
    }

    /// has parsed href => parse url
    if (galleryDownloadInfo.imageHrefs[serialNo] != null) {
      return _submitTask(
        gid: gallery.gid,
        priority: _computeImageTaskPriority(gallery, serialNo),
        task: _parseImageUrlTask(gallery, serialNo),
      );
    }

    /// has not parsed href => parse href
    _submitTask(
      gid: gallery.gid,
      priority: _computeImageTaskPriority(gallery, serialNo),
      task: _parseImageHrefTask(gallery, serialNo),
    );
  }

  AsyncTask<void> _parseImageHrefTask(GalleryDownloadedData gallery, int serialNo) {
    return () async {
      if (_taskHasBeenPausedOrRemoved(gallery)) {
        return;
      }

      GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;

      Map<String, dynamic> rangeAndThumbnails;
      try {
        rangeAndThumbnails = await retry(
          () => EHRequest.requestDetailPage(
            galleryUrl: gallery.galleryUrl,
            thumbnailsPageIndex: serialNo ~/ galleryDownloadInfo.thumbnailsCountPerPage,
            cancelToken: galleryDownloadInfo.cancelToken,
            parser: EHSpiderParser.detailPage2RangeAndThumbnails,
          ),
          retryIf: (e) => e is DioException && e.type != DioExceptionType.cancel,
          onRetry: (e) => Log.download('Parse image hrefs failed, retry. Reason: ${(e as DioException).toString()}'),
          maxAttempts: _maxRetryTimes,
        );
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          return;
        }
        return _submitTask(
          gid: gallery.gid,
          priority: _computeImageTaskPriority(gallery, serialNo),
          task: _parseImageHrefTask(gallery, serialNo),
        );
      } on EHSiteException catch (e) {
        Log.download('Parse image href error, reason: ${e.message}, gallery url: ${gallery.galleryUrl}');
        snack('error'.tr, e.message, longDuration: true);
        if (e.shouldPauseAllDownloadTasks) {
          pauseAllDownloadGallery();
        } else {
          pauseDownloadGallery(gallery);
        }
        return;
      }

      int rangeFrom = rangeAndThumbnails['rangeIndexFrom'];
      int rangeTo = rangeAndThumbnails['rangeIndexTo'];
      List<GalleryThumbnail> thumbnails = rangeAndThumbnails['thumbnails'];

      /// some gallery's [thumbnailsCountPerPage] is not equal to default setting, we need to compute and update it.
      /// For example, default setting is 40, but some gallerys' thumbnails has only high quality thumbnails, which results in 20.
      galleryDownloadInfo.thumbnailsCountPerPage = (thumbnails.length / 20).ceil() * 20;

      for (int i = rangeFrom; i <= rangeTo; i++) {
        galleryDownloadInfo.imageHrefs[i] = thumbnails[i - rangeFrom];
      }

      /// if gallery's [thumbnailsCountPerPage] is not equal to default setting, we probably can't get target thumbnails this turn
      /// because the [thumbnailsPageIndex] we computed before is wrong, so we need to parse again
      if (galleryDownloadInfo.imageHrefs[serialNo] == null) {
        Log.download('Parse image hrefs error, thumbnails count per page is not equal to default setting, parse again');
        return _submitTask(
          gid: gallery.gid,
          priority: _computeImageTaskPriority(gallery, serialNo),
          task: _parseImageHrefTask(gallery, serialNo),
        );
      }

      /// Next step: parse image url
      _submitTask(
        gid: gallery.gid,
        priority: _computeImageTaskPriority(gallery, serialNo),
        task: _parseImageUrlTask(gallery, serialNo),
      );
    };
  }

  AsyncTask<void> _parseImageUrlTask(GalleryDownloadedData gallery, int serialNo, {bool reParse = false, String? reloadKey}) {
    return () async {
      if (_taskHasBeenPausedOrRemoved(gallery)) {
        return;
      }

      GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;

      GalleryImage image;
      try {
        image = await retry(
          () => EHRequest.requestImagePage(
            galleryDownloadInfo.imageHrefs[serialNo]!.href,
            reloadKey: reloadKey,
            cancelToken: galleryDownloadInfo.cancelToken,
            useCacheIfAvailable: !reParse,
            parser: gallery.downloadOriginalImage && UserSetting.hasLoggedIn()
                ? EHSpiderParser.imagePage2OriginalGalleryImage
                : EHSpiderParser.imagePage2GalleryImage,
          ),
          retryIf: (e) => e is DioException && e.type != DioExceptionType.cancel,
          onRetry: (e) => Log.download('Parse image url failed, retry. Reason: ${(e as DioException).toString()}'),
          maxAttempts: _maxRetryTimes,
        );
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          return;
        }
        return _submitTask(
          gid: gallery.gid,
          priority: _computeImageTaskPriority(gallery, serialNo),
          task: _parseImageUrlTask(gallery, serialNo, reParse: true),
        );
      } on EHParseException catch (e) {
        Log.download('Parse image url error, reason: ${e.message.tr}');
        snack('error'.tr, e.message.tr, longDuration: true);

        if (e.shouldPauseAllDownloadTasks) {
          pauseAllDownloadGallery();
        } else {
          pauseDownloadGallery(gallery);
        }

        EHRequest.removeCacheByEHUrl(galleryDownloadInfo.imageHrefs[serialNo]!.href);

        return;
      } on EHSiteException catch (e) {
        Log.download('Parse image url error, reason: ${e.message.tr}');
        snack('error'.tr, e.message.tr, longDuration: true);

        if (e.shouldPauseAllDownloadTasks) {
          pauseAllDownloadGallery();
        } else {
          pauseDownloadGallery(gallery);
        }

        return;
      }

      image.path = _computeImageDownloadRelativePath(gallery.title, gallery.gid, image.url, serialNo);
      image.downloadStatus = DownloadStatus.downloading;

      await _saveNewImageInfoInDatabase(image, serialNo, gallery.gid);

      galleryDownloadInfo.images[serialNo] = image;

      Log.download('Parse image url success, index: $serialNo, url: ${image.url}');

      /// Next step: download image
      return _submitTask(
        gid: gallery.gid,
        priority: _computeImageTaskPriority(gallery, serialNo),
        task: _downloadImageTask(gallery, serialNo),
      );
    };
  }

  AsyncTask<void> _downloadImageTask(GalleryDownloadedData gallery, int serialNo) {
    return () async {
      if (_taskHasBeenPausedOrRemoved(gallery)) {
        return;
      }

      GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;
      GalleryImage image = galleryDownloadInfo.images[serialNo]!;

      _updateImageStatus(gallery, image, serialNo, DownloadStatus.downloading);

      /// If this is a update from old gallery, try to copy from existing old image first
      if (gallery.oldVersionGalleryUrl != null) {
        await _tryCopyImageInfo(gallery.oldVersionGalleryUrl!, gallery, serialNo);

        if (image.downloadStatus == DownloadStatus.downloaded) {
          return;
        }
      }

      String path = _computeImageDownloadAbsolutePath(gallery.title, gallery.gid, image.url, serialNo);

      await _tryLoadFromCacheInsteadDownload(gallery, image, serialNo, path);
      if (image.downloadStatus == DownloadStatus.downloaded) {
        return;
      }

      Response response;
      try {
        response = await retry(
          () => EHRequest.download(
            url: image.url,
            path: path,
            receiveTimeout: 3 * 60 * 1000,
            cancelToken: galleryDownloadInfo.cancelToken,
            onReceiveProgress: (int count, int total) => galleryDownloadInfo.speedComputer.updateProgress(count, total, serialNo),
          ),
          maxAttempts: _maxRetryTimes,

          /// 403 is due to broken H@H node, we should re-parse
          /// If we have not downloaded any bytes, we should re-parse because we might encounter a death H@H node
          retryIf: (e) =>
              e is DioException &&
              e.type != DioExceptionType.cancel &&
              (e.response == null || e.response!.statusCode != 403) &&
              galleryDownloadInfo.speedComputer.getImageDownloadedBytes(serialNo) > 0,
          onRetry: (e) {
            Log.download('Download ${gallery.title} image: $serialNo failed, retry. Reason: ${(e as DioException).toString()}. Url:${image.url}');
            galleryDownloadInfo.speedComputer.resetProgress(serialNo);
          },
        );
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          return;
        }
        Log.download('Download ${gallery.title} image: $serialNo failed, try re-parse. Reason: ${e.message}. Url:${image.url}');
        return _reParseImageUrlAndDownload(gallery, serialNo);
      } on EHSiteException catch (e) {
        Log.download('Download Error, reason: ${e.message}');
        snack('error'.tr, e.message, longDuration: true);

        if (e.shouldPauseAllDownloadTasks) {
          pauseAllDownloadGallery();
        } else {
          pauseDownloadGallery(gallery);
        }
        return;
      }

      /// what we downloaded is not an image
      if (gallery.downloadOriginalImage &&
          !response.isRedirect &&
          (response.headers[Headers.contentTypeHeader]?.contains("text/html; charset=UTF-8") ?? false)) {
        String data = io.File(path).readAsStringSync();

        /// Sometimes we need gp to download original image, but gp is not enough, we should pause this gallery
        if (data.contains('Downloading original files of this gallery during peak hours requires GP, and you do not have enough.')) {
          Log.error('Download ${gallery.title} image: $serialNo failed, gp not enough');
          snack('error'.tr, 'gpNotEnoughHint'.tr, longDuration: true);
          return pauseDownloadGallery(gallery);
        }

        /// We need a token in url to get the original image download url, expired token will leads to a failed request,
        if (data.contains('Invalid token')) {
          Log.warning('Invalid original image token, url: ${image.url}');
          return _reParseImageUrlAndDownload(gallery, serialNo);
        }
      }

      Log.download('Download ${gallery.title} image: $serialNo success');

      await _updateImageStatus(gallery, image, serialNo, DownloadStatus.downloaded);

      await _updateProgressAfterImageDownloaded(gallery, serialNo);
    };
  }

  /// the image's url may be invalid, try re-parse and then download
  Future<void> _reParseImageUrlAndDownload(GalleryDownloadedData gallery, int serialNo) async {
    if (_taskHasBeenPausedOrRemoved(gallery)) {
      return;
    }

    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;

    String? reloadKey = galleryDownloadInfo.images[serialNo]?.reloadKey;
    galleryDownloadInfo.images[serialNo] = null;
    await GalleryImageDao.deleteImage(gallery.gid, serialNo);

    /// has parsed href => parse url
    if (galleryDownloadInfo.imageHrefs[serialNo] != null) {
      return _submitTask(
        gid: gallery.gid,
        priority: _computeImageTaskPriority(gallery, serialNo),
        task: _parseImageUrlTask(gallery, serialNo, reParse: true, reloadKey: reloadKey),
      );
    }

    /// has not parsed href => parse href
    return _submitTask(
      gid: gallery.gid,
      priority: _computeImageTaskPriority(gallery, serialNo),
      task: _parseImageHrefTask(gallery, serialNo),
    );
  }

  /// If two images' [imageHash] is equal, they are the same image.
  Future<void> _tryCopyImageInfo(String oldVersionGalleryUrl, GalleryDownloadedData newGallery, int newImageSerialNo) async {
    GalleryDownloadedData? oldGallery = gallerys.firstWhereOrNull((e) => e.galleryUrl == oldVersionGalleryUrl);
    if (oldGallery == null) {
      return;
    }

    String newImageHash = galleryDownloadInfos[newGallery.gid]!.images[newImageSerialNo]!.imageHash!;
    int? oldImageSerialNo = galleryDownloadInfos[oldGallery.gid]?.images.firstIndexWhereOrNull((e) => e?.imageHash == newImageHash);
    if (oldImageSerialNo == null) {
      return;
    }

    GalleryImage oldImage = galleryDownloadInfos[oldGallery.gid]!.images[oldImageSerialNo]!;

    await _copyImageInfo(oldImage, newGallery, newImageSerialNo);
    await Get.find<SuperResolutionService>().copyImageInfo(oldGallery, newGallery, oldImageSerialNo, newImageSerialNo);
  }

  Future<void> _copyImageInfo(GalleryImage oldImage, GalleryDownloadedData newGallery, int newImageSerialNo) async {
    Log.download('Copy old image, new serialNo: $newImageSerialNo');

    GalleryImage newImage = galleryDownloadInfos[newGallery.gid]!.images[newImageSerialNo]!;

    io.File oldFile = io.File(path.join(PathSetting.getVisibleDir().path, oldImage.path!));
    oldFile.copySync(path.join(PathSetting.getVisibleDir().path, newImage.path!));

    await _updateImageStatus(newGallery, newImage, newImageSerialNo, DownloadStatus.downloaded);

    await _updateProgressAfterImageDownloaded(newGallery, newImageSerialNo);
  }

  Future<void> _tryLoadFromCacheInsteadDownload(GalleryDownloadedData gallery, GalleryImage image, int serialNo, String path) async {
    io.File? cachedImageFile = await getCachedImageFile(image.url);
    if (cachedImageFile != null && cachedImageFile.existsSync()) {
      Log.debug('download image from cache, gallery: ${gallery.gid}, serialNo:$serialNo');
      cachedImageFile.copySync(path);
      await _updateImageStatus(gallery, image, serialNo, DownloadStatus.downloaded);
      await _updateProgressAfterImageDownloaded(gallery, serialNo);
    }
  }

  Future<void> _updateProgressAfterImageDownloaded(GalleryDownloadedData gallery, int serialNo) async {
    if (_taskHasBeenPausedOrRemoved(gallery)) {
      return;
    }

    GalleryDownloadProgress downloadProgress = galleryDownloadInfos[gallery.gid]!.downloadProgress;
    downloadProgress.curCount++;
    downloadProgress.hasDownloaded[serialNo] = true;

    if (downloadProgress.curCount == downloadProgress.totalCount) {
      downloadProgress.downloadStatus = DownloadStatus.downloaded;
      await _updateGalleryDownloadStatus(gallery, DownloadStatus.downloaded);
      galleryDownloadInfos[gallery.gid]!.speedComputer.dispose();
      update(['$galleryDownloadSuccessId::${gallery.gid}']);
    }

    update(['$galleryDownloadProgressId::${gallery.gid}']);
  }

  // ALL

  Future<void> _instantiateFromDB() async {
    allGroups = (await GalleryGroupDao.selectGalleryGroups()).map((e) => e.groupName).toList();
    Log.debug('init Gallery groups: $allGroups');

    /// Get download info from database
    List<GalleryDownloadedData> gallerys = await GalleryDao.selectGallerys();
    List<ImageData> images = await GalleryImageDao.selectImages();
    Map<int, List<ImageData>> gid2Images = groupBy(images, (e) => e.gid);

    for (GalleryDownloadedData gallery in gallerys) {
      /// Instantiate [Gallery]
      _initGalleryInfoInMemory(gallery, sort: false);

      /// Instantiate [GalleryImage]
      List<ImageData>? galleryImages = gid2Images[gallery.gid];
      if (galleryImages != null) {
        for (ImageData image in galleryImages) {
          GalleryImage galleryImage = GalleryImage(
            url: image.url,
            path: image.path,
            imageHash: image.imageHash,
            downloadStatus: DownloadStatus.values[image.downloadStatusIndex],
          );

          galleryDownloadInfos[gallery.gid]!.images[image.serialNo] = galleryImage;
          if (galleryImage.downloadStatus == DownloadStatus.downloaded) {
            galleryDownloadInfos[gallery.gid]!.downloadProgress.curCount++;
            galleryDownloadInfos[gallery.gid]!.downloadProgress.hasDownloaded[image.serialNo] = true;
          }
        }
      }
    }

    // sort after instantiated
    _sortGallerys();
  }

  Future<bool> _initGalleryInfo(GalleryDownloadedData gallery) async {
    if (!await _saveGalleryInfoAndGroupInDB(gallery)) {
      return false;
    }

    _initGalleryInfoInMemory(gallery);

    _saveGalleryInfoInDisk(gallery);

    return true;
  }

  Future<void> _updateGalleryDownloadStatus(GalleryDownloadedData gallery, DownloadStatus downloadStatus) async {
    await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(gid: Value(gallery.gid), downloadStatusIndex: Value(downloadStatus.index)),
    );

    gallerys[gallerys.indexWhere((e) => e.gid == gallery.gid)] = gallery.copyWith(downloadStatusIndex: downloadStatus.index);
    galleryDownloadInfos[gallery.gid]!.downloadProgress.downloadStatus = downloadStatus;

    _saveGalleryInfoInDisk(gallery);
  }

  Future<bool> _updateImageStatus(GalleryDownloadedData gallery, GalleryImage image, int serialNo, DownloadStatus downloadStatus) async {
    if (!await _updateImageInDatabase(
      ImageCompanion(gid: Value(gallery.gid), serialNo: Value(serialNo), downloadStatusIndex: Value(downloadStatus.index)),
    )) {
      return false;
    }

    image.downloadStatus = downloadStatus;

    update(['$downloadImageId::${gallery.gid}::$serialNo', '$downloadImageUrlId::${gallery.gid}::$serialNo']);

    _saveGalleryInfoInDisk(gallery);

    return true;
  }

  Future<bool> _addGroup(String group) async {
    if (!allGroups.contains(group)) {
      allGroups.add(group);
    }

    return (await GalleryGroupDao.insertGalleryGroup(GalleryGroupData(groupName: group, sortOrder: 0)) > 0);
  }

  Future<bool> _deleteGroup(String group) async {
    allGroups.remove(group);

    try {
      return (await GalleryGroupDao.deleteGalleryGroup(group) > 0);
    } on SqliteException catch (e) {
      Log.info(e);
      return false;
    }
  }

  // MEMORY

  void _initGalleryInfoInMemory(GalleryDownloadedData gallery, {List<GalleryImage?>? images, bool sort = true}) {
    if (!allGroups.contains(gallery.groupName)) {
      allGroups.add(gallery.groupName);
    }
    gallerys.add(gallery);
    galleryDownloadInfos[gallery.gid] = GalleryDownloadInfo(
      thumbnailsCountPerPage: SiteSetting.thumbnailsCountPerPage.value,
      tasks: [],
      cancelToken: CancelToken(),
      downloadProgress: GalleryDownloadProgress(
        curCount: images?.fold<int>(0, (total, image) => total + (image?.downloadStatus == DownloadStatus.downloaded ? 1 : 0)) ?? 0,
        totalCount: gallery.pageCount,
        downloadStatus: DownloadStatus.values[gallery.downloadStatusIndex],
        hasDownloaded: images?.map((image) => image?.downloadStatus == DownloadStatus.downloaded).toList() ?? List.generate(gallery.pageCount, (_) => false),
      ),
      imageHrefs: List.generate(gallery.pageCount, (_) => null),
      images: images ?? List.generate(gallery.pageCount, (_) => null),
      speedComputer: GalleryDownloadSpeedComputer(
        gallery.pageCount,
        () => update(['$galleryDownloadSpeedComputerId::${gallery.gid}']),
      ),
      priority: gallery.priority,
      sortOrder: gallery.sortOrder,
      group: gallery.groupName,
    );

    if (sort) {
      _sortGallerys();
    }

    update([galleryCountChangedId, '$galleryDownloadProgressId::${gallery.gid}']);
  }

  void _clearGalleryInfoInMemory(GalleryDownloadedData gallery) {
    gallerys.removeWhere((g) => g.gid == gallery.gid);
    GalleryDownloadInfo? galleryDownloadInfo = galleryDownloadInfos.remove(gallery.gid);
    galleryDownloadInfo?.speedComputer.dispose();

    update([galleryCountChangedId, '$galleryDownloadProgressId::${gallery.gid}']);
  }

  // DB

  Future<bool> _saveGalleryInfoAndGroupInDB(GalleryDownloadedData gallery) async {
    return appDb.transaction(() async {
      await GalleryGroupDao.insertGalleryGroup(GalleryGroupData(groupName: gallery.groupName, sortOrder: 0));

      return await GalleryDao.insertGallery(
            GalleryDownloadedData(
              gid: gallery.gid,
              token: gallery.token,
              title: gallery.title,
              category: gallery.category,
              pageCount: gallery.pageCount,
              galleryUrl: gallery.galleryUrl,
              oldVersionGalleryUrl: gallery.oldVersionGalleryUrl,
              uploader: gallery.uploader,
              publishTime: gallery.publishTime,
              downloadStatusIndex: gallery.downloadStatusIndex,
              insertTime: gallery.insertTime,
              downloadOriginalImage: gallery.downloadOriginalImage,
              priority: gallery.priority,
              sortOrder: gallery.sortOrder,
              groupName: gallery.groupName,
            ),
          ) >
          0;
    });
  }

  Future<bool> _saveNewImageInfoInDatabase(GalleryImage image, int serialNo, int gid) async {
    return await GalleryImageDao.insertImage(
          ImageData(
            gid: gid,
            serialNo: serialNo,
            url: image.url,
            path: image.path!,
            imageHash: image.imageHash!,
            downloadStatusIndex: image.downloadStatus.index,
          ),
        ) >
        0;
  }

  Future<bool> _updateGalleryInDatabase(GalleryDownloadedCompanion gallery) async {
    return await GalleryDao.updateGallery(gallery) > 0;
  }

  Future<bool> _updateImageInDatabase(ImageCompanion image) async {
    return await GalleryImageDao.updateImage(image) > 0;
  }

  Future<void> _clearGalleryDownloadInfoInDatabase(int gid) {
    return appDb.transaction(() async {
      await GalleryImageDao.deleteImagesWithGid(gid);
      await GalleryDao.deleteGallery(gid);
    });
  }

  Future<bool> _restoreInfoInDatabase(GalleryDownloadedData gallery, List<GalleryImage?> images) async {
    if (gallery.downloadStatusIndex == DownloadStatus.downloading.index) {
      gallery = gallery.copyWith(downloadStatusIndex: DownloadStatus.paused.index);
    }

    if (!await _saveGalleryInfoAndGroupInDB(gallery)) {
      return false;
    }

    return await appDb.transaction(() async {
      int serialNo = 0;

      Iterator iterator = images.iterator;
      while (iterator.moveNext()) {
        GalleryImage? image = iterator.current;

        if (image == null) {
          serialNo++;
          continue;
        }

        if (!await _saveNewImageInfoInDatabase(image, serialNo++, gallery.gid)) {
          return false;
        }
      }

      return true;
    }).catchError((e) {
      Log.error('Restore images into database error}', e);
      Log.uploadError(e);
      return false;
    });
  }

  // Disk

  void _saveGalleryInfoInDisk(GalleryDownloadedData gallery) {
    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;

    Map<String, Object> metadata = {
      'gallery': gallery
          .copyWith(
            downloadStatusIndex: galleryDownloadInfo.downloadProgress.downloadStatus.index,
            priority: galleryDownloadInfo.priority,
            groupName: galleryDownloadInfo.group,
          )
          .toJson(),
      'images': jsonEncode(galleryDownloadInfo.images),
    };

    io.File file = io.File(path.join(computeGalleryDownloadPath(gallery.title, gallery.gid), metadataFileName));
    if (!file.existsSync()) {
      file.createSync(recursive: true);
    }
    file.writeAsStringSync(jsonEncode(metadata));
  }

  void _clearDownloadedImageInDisk(GalleryDownloadedData gallery) {
    io.Directory directory = io.Directory(computeGalleryDownloadPath(gallery.title, gallery.gid));
    if (!directory.existsSync()) {
      return;
    }
    directory.deleteSync(recursive: true);
  }

  void _deleteImageInDisk(GalleryImage image) {
    try {
      io.File file = io.File(image.path!);
      if (!file.existsSync()) {
        return;
      }
      file.deleteSync();
    } on Exception catch (e) {
      Log.error('Delete image in disk error', e);
      Log.uploadError(e);
    }
  }

  void _ensureDownloadDirExists() {
    try {
      io.Directory(DownloadSetting.downloadPath.value).createSync(recursive: true);
    } on Exception catch (e) {
      toast('brokenDownloadPathHint'.tr);
      Log.error(e);
      Log.uploadError(
        e,
        extraInfos: {
          'defaultDownloadPath': DownloadSetting.defaultDownloadPath,
          'downloadPath': DownloadSetting.downloadPath.value,
          'exists': PathSetting.getVisibleDir().existsSync(),
        },
      );
    }
  }
}

enum DownloadStatus {
  none,
  switching,
  paused,
  downloading,
  downloaded,
  downloadFailed,
}

class GalleryDownloadInfo {
  /// 20, 40 and so on
  int thumbnailsCountPerPage;

  /// Tasks in Executor
  List<AsyncTask> tasks;

  /// Token for cancel all tasks related to a gallery
  CancelToken cancelToken;

  GalleryDownloadProgress downloadProgress;

  /// Thumbnail related to a image, whose property [href] is the page url which contains the image
  List<GalleryThumbnail?> imageHrefs;

  List<GalleryImage?> images;

  GalleryDownloadSpeedComputer speedComputer;

  int priority;

  int sortOrder;

  String group;

  GalleryDownloadInfo({
    required this.thumbnailsCountPerPage,
    required this.tasks,
    required this.cancelToken,
    required this.downloadProgress,
    required this.imageHrefs,
    required this.images,
    required this.speedComputer,
    required this.priority,
    required this.sortOrder,
    required this.group,
  });
}

class GalleryDownloadProgress {
  /// downloaded images count
  int curCount;

  /// total images count
  int totalCount;

  DownloadStatus downloadStatus;

  List<bool> hasDownloaded;

  GalleryDownloadProgress({
    required this.curCount,
    required this.totalCount,
    required this.downloadStatus,
    required this.hasDownloaded,
  });

  Map<String, dynamic> toJson() {
    return {
      "curCount": curCount,
      "totalCount": totalCount,
      "downloadStatus": downloadStatus.index,
      "hasDownloaded": jsonEncode(hasDownloaded),
    };
  }

  factory GalleryDownloadProgress.fromJson(Map<String, dynamic> json) {
    return GalleryDownloadProgress(
      curCount: json["curCount"],
      totalCount: json["totalCount"],
      downloadStatus: DownloadStatus.values[json["downloadStatus"]],
      hasDownloaded: (jsonDecode(json["hasDownloaded"]) as List).cast<bool>(),
    );
  }
}

/// Compute gallery download speed during last period every second
class GalleryDownloadSpeedComputer extends SpeedComputer {
  List<int> imageDownloadedBytes;
  List<int> imageTotalBytes;

  GalleryDownloadSpeedComputer(int pageCount, VoidCallback updateCallback)
      : imageDownloadedBytes = List.generate(pageCount, (_) => 0),
        imageTotalBytes = List.generate(pageCount, (_) => 1),
        super(updateCallback: updateCallback);

  void updateProgress(int current, int total, int serialNo) {
    imageTotalBytes[serialNo] = total;

    downloadedBytes -= imageDownloadedBytes[serialNo];
    imageDownloadedBytes[serialNo] = current;
    downloadedBytes += imageDownloadedBytes[serialNo];
  }

  /// one image download failed
  void resetProgress(int serialNo) {
    downloadedBytes -= imageDownloadedBytes[serialNo];
    imageDownloadedBytes[serialNo] = 0;
  }

  int getImageDownloadedBytes(int serialNo) {
    return imageDownloadedBytes[serialNo];
  }
}
