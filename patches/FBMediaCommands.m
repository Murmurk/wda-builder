#import "FBMediaCommands.h"
#import <Photos/Photos.h>
#import <XCTest/XCTest.h>
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBResponsePayload.h"
#import "FBCommandStatus.h"

@implementation FBMediaCommands

+ (NSArray *)routes
{
  return @[
    [[FBRoute POST:@"/wda/saveMedia"].withoutSession respondWithTarget:self action:@selector(handleSaveMedia:)],
    [[FBRoute POST:@"/wda/saveMedia"] respondWithTarget:self action:@selector(handleSaveMedia:)],
    [[FBRoute POST:@"/wda/deleteMedia"].withoutSession respondWithTarget:self action:@selector(handleDeleteMedia:)],
    [[FBRoute POST:@"/wda/deleteMedia"] respondWithTarget:self action:@selector(handleDeleteMedia:)],
    [[FBRoute GET:@"/wda/listMedia"].withoutSession respondWithTarget:self action:@selector(handleListMedia:)],
    [[FBRoute GET:@"/wda/listMedia"] respondWithTarget:self action:@selector(handleListMedia:)],
    [[FBRoute POST:@"/wda/authorizePhotos"].withoutSession respondWithTarget:self action:@selector(handleAuthorizePhotos:)],
    [[FBRoute POST:@"/wda/authorizePhotos"] respondWithTarget:self action:@selector(handleAuthorizePhotos:)],
  ];
}

#pragma mark - Authorization

+ (PHAuthorizationStatus)currentAuthStatus
{
  if (@available(iOS 14, *)) {
    return [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
  }
  return [PHPhotoLibrary authorizationStatus];
}

+ (PHAuthorizationStatus)requestAuthAndWait:(NSTimeInterval)timeout
{
  __block PHAuthorizationStatus result = PHAuthorizationStatusNotDetermined;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  if (@available(iOS 14, *)) {
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                               handler:^(PHAuthorizationStatus status) {
      result = status;
      dispatch_semaphore_signal(sem);
    }];
  } else {
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
      result = status;
      dispatch_semaphore_signal(sem);
    }];
  }
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
  return result;
}

+ (void)autoAcceptPhotosAlertWithTimeout:(NSTimeInterval)timeout
{
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    XCUIApplication *springboard = [[XCUIApplication alloc]
                                    initWithBundleIdentifier:@"com.apple.springboard"];
    NSTimeInterval deadline = [NSDate date].timeIntervalSince1970 + timeout;
    while ([NSDate date].timeIntervalSince1970 < deadline) {
      @autoreleasepool {
        @try {
          XCUIElementQuery *alerts = springboard.alerts;
          if (alerts.count == 0) {
            [NSThread sleepForTimeInterval:0.3];
            continue;
          }
          XCUIElement *alert = alerts.firstMatch;
          if (!alert.exists) {
            [NSThread sleepForTimeInterval:0.3];
            continue;
          }
          NSArray<NSString *> *wanted = @[
            @"Allow Full Access",
            @"Allow Access to All Photos",
            @"Разрешить полный доступ"
          ];
          BOOL tapped = NO;
          for (NSString *label in wanted) {
            XCUIElement *btn = alert.buttons[label];
            if (btn.exists && btn.isHittable) {
              [btn tap];
              tapped = YES;
              break;
            }
          }
          if (tapped) return;
          XCUIElement *allow = alert.buttons[@"Allow"];
          if (allow.exists && allow.isHittable) {
            [allow tap];
            return;
          }
        } @catch (NSException *e) {
          // springboard query может бросить при переходном состоянии — игнорируем
        }
        [NSThread sleepForTimeInterval:0.5];
      }
    }
  });
}

+ (NSString *)statusStringForAuth:(PHAuthorizationStatus)status
{
  switch (status) {
    case PHAuthorizationStatusAuthorized: return @"authorized";
    case PHAuthorizationStatusDenied: return @"denied";
    case PHAuthorizationStatusRestricted: return @"restricted";
    case PHAuthorizationStatusNotDetermined: return @"not_determined";
    default: return @"limited";
  }
}

+ (id<FBResponsePayload>)handleAuthorizePhotos:(FBRouteRequest *)request
{
  PHAuthorizationStatus status = [self currentAuthStatus];

  if (status == PHAuthorizationStatusAuthorized || status == 4 /* Limited */) {
    return FBResponseWithObject(@{
      @"status": [self statusStringForAuth:status],
      @"statusCode": @(status),
      @"autoAccepted": @(NO)
    });
  }

  if (status != PHAuthorizationStatusNotDetermined) {
    return FBResponseWithObject(@{
      @"status": [self statusStringForAuth:status],
      @"statusCode": @(status),
      @"autoAccepted": @(NO)
    });
  }

  [self autoAcceptPhotosAlertWithTimeout:30.0];
  [NSThread sleepForTimeInterval:0.5];

  status = [self requestAuthAndWait:60.0];

  // Poll until iOS actually updates the status after alert accept
  for (int i = 0; i < 20 && (status == PHAuthorizationStatusNotDetermined); i++) {
    [NSThread sleepForTimeInterval:0.5];
    status = [self currentAuthStatus];
  }

  return FBResponseWithObject(@{
    @"status": [self statusStringForAuth:status],
    @"statusCode": @(status),
    @"autoAccepted": @(YES)
  });
}

#pragma mark - Save

+ (id<FBResponsePayload>)handleSaveMedia:(FBRouteRequest *)request
{
  NSString *b64 = request.arguments[@"data"];
  NSString *mediaType = request.arguments[@"mediaType"];
  NSString *filename = request.arguments[@"filename"];

  if (!b64 || b64.length == 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:
      @"'data' (base64) is required" traceback:nil]);
  }

  NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
  if (!data || data.length == 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:
      @"Failed to decode base64 'data'" traceback:nil]);
  }

  PHAuthorizationStatus authStatus = [self currentAuthStatus];
  if (authStatus == PHAuthorizationStatusNotDetermined) {
    [self autoAcceptPhotosAlertWithTimeout:30.0];
    [NSThread sleepForTimeInterval:0.5];
    authStatus = [self requestAuthAndWait:60.0];
    for (int i = 0; i < 20 && (authStatus == PHAuthorizationStatusNotDetermined); i++) {
      [NSThread sleepForTimeInterval:0.5];
      authStatus = [self currentAuthStatus];
    }
  }
  if (authStatus != PHAuthorizationStatusAuthorized
      && authStatus != 4 /* PHAuthorizationStatusLimited */) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:
      @"Photos not authorized. Call /wda/authorizePhotos first and accept the dialog" traceback:nil]);
  }

  NSString *ext = @"jpg";
  if (filename) {
    ext = [[filename pathExtension] lowercaseString];
  }
  if ([mediaType isEqualToString:@"video"] && (!ext || ext.length == 0 || [ext isEqualToString:@"jpg"])) {
    ext = @"mp4";
  }
  BOOL isVideo = [mediaType isEqualToString:@"video"] ||
                 [@[@"mp4", @"mov", @"m4v", @"avi", @"3gp"] containsObject:ext];

  NSString *tempDir = NSTemporaryDirectory();
  NSString *fileName = [NSString stringWithFormat:@"wda_%@.%@", [[NSUUID UUID] UUIDString], ext.length ? ext : @"jpg"];
  NSString *tempPath = [tempDir stringByAppendingPathComponent:fileName];
  [data writeToFile:tempPath atomically:YES];
  NSURL *fileURL = [NSURL fileURLWithPath:tempPath];

  __block NSString *assetId = nil;
  __block NSError *saveError = nil;
  dispatch_semaphore_t saveSem = dispatch_semaphore_create(0);

  [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
    PHAssetCreationRequest *req;
    if (isVideo) {
      req = [PHAssetCreationRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
    } else {
      req = [PHAssetCreationRequest creationRequestForAssetFromImageAtFileURL:fileURL];
    }
    if (req.placeholderForCreatedAsset) {
      assetId = req.placeholderForCreatedAsset.localIdentifier;
    }
  } completionHandler:^(BOOL success, NSError *error) {
    if (!success) saveError = error;
    dispatch_semaphore_signal(saveSem);
  }];
  dispatch_semaphore_wait(saveSem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));

  [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

  if (saveError) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:saveError.localizedDescription traceback:nil]);
  }

  return FBResponseWithObject(@{
    @"assetId": assetId ?: @"unknown",
    @"isVideo": @(isVideo),
    @"size": @(data.length),
  });
}

#pragma mark - Delete

+ (id<FBResponsePayload>)handleDeleteMedia:(FBRouteRequest *)request
{
  NSString *assetId = request.arguments[@"assetId"];
  NSArray *assetIds = request.arguments[@"assetIds"];
  BOOL deleteAll = [request.arguments[@"deleteAll"] boolValue];

  PHFetchResult<PHAsset *> *assets;
  if (deleteAll) {
    assets = [PHAsset fetchAssetsWithOptions:nil];
  } else if (assetIds && [assetIds isKindOfClass:[NSArray class]]) {
    assets = [PHAsset fetchAssetsWithLocalIdentifiers:assetIds options:nil];
  } else if (assetId) {
    assets = [PHAsset fetchAssetsWithLocalIdentifiers:@[assetId] options:nil];
  } else {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:
      @"Provide 'assetId', 'assetIds' array, or 'deleteAll':true" traceback:nil]);
  }

  if (assets.count == 0) {
    return FBResponseWithObject(@{@"deleted": @(0)});
  }

  __block NSError *delError = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);

  [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
    [PHAssetChangeRequest deleteAssets:assets];
  } completionHandler:^(BOOL success, NSError *error) {
    if (!success) delError = error;
    dispatch_semaphore_signal(sem);
  }];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

  if (delError) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:delError.localizedDescription traceback:nil]);
  }

  return FBResponseWithObject(@{@"deleted": @(assets.count)});
}

#pragma mark - List

+ (id<FBResponsePayload>)handleListMedia:(FBRouteRequest *)request
{
  NSNumber *limit = request.arguments[@"limit"] ?: @(100);
  NSString *mediaType = request.arguments[@"mediaType"];

  PHFetchOptions *options = [[PHFetchOptions alloc] init];
  options.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
  options.fetchLimit = limit.unsignedIntegerValue;
  if ([mediaType isEqualToString:@"video"]) {
    options.predicate = [NSPredicate predicateWithFormat:@"mediaType == %d", PHAssetMediaTypeVideo];
  } else if ([mediaType isEqualToString:@"image"]) {
    options.predicate = [NSPredicate predicateWithFormat:@"mediaType == %d", PHAssetMediaTypeImage];
  }

  PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithOptions:options];
  NSMutableArray *result = [NSMutableArray array];

  [assets enumerateObjectsUsingBlock:^(PHAsset *asset, NSUInteger idx, BOOL *stop) {
    [result addObject:@{
      @"id": asset.localIdentifier,
      @"type": asset.mediaType == PHAssetMediaTypeVideo ? @"video" : @"image",
      @"width": @(asset.pixelWidth),
      @"height": @(asset.pixelHeight),
      @"duration": @(asset.duration),
      @"createdAt": asset.creationDate ? asset.creationDate.description : @"",
    }];
  }];

  return FBResponseWithObject(@{@"assets": result, @"count": @(result.count)});
}

@end
