#import "FBMediaCommands.h"
#import <Photos/Photos.h>
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

+ (id<FBResponsePayload>)handleAuthorizePhotos:(FBRouteRequest *)request
{
  PHAuthorizationStatus status = [self currentAuthStatus];
  if (status == PHAuthorizationStatusNotDetermined) {
    status = [self requestAuthAndWait:60.0];
  }
  NSString *statusStr;
  switch (status) {
    case PHAuthorizationStatusAuthorized: statusStr = @"authorized"; break;
    case PHAuthorizationStatusDenied: statusStr = @"denied"; break;
    case PHAuthorizationStatusRestricted: statusStr = @"restricted"; break;
    case PHAuthorizationStatusNotDetermined: statusStr = @"not_determined"; break;
    default: statusStr = @"limited"; break;
  }
  return FBResponseWithObject(@{@"status": statusStr, @"statusCode": @(status)});
}

#pragma mark - Save

+ (id<FBResponsePayload>)handleSaveMedia:(FBRouteRequest *)request
{
  NSString *urlString = request.arguments[@"url"];
  if (!urlString) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'url' is required" traceback:nil]);
  }
  NSURL *url = [NSURL URLWithString:urlString];
  if (!url) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Invalid URL" traceback:nil]);
  }

  PHAuthorizationStatus authStatus = [self currentAuthStatus];
  if (authStatus == PHAuthorizationStatusNotDetermined) {
    authStatus = [self requestAuthAndWait:30.0];
  }
  if (authStatus != PHAuthorizationStatusAuthorized
      && authStatus != 4 /* PHAuthorizationStatusLimited */) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:
      @"Photos not authorized. Call /wda/authorizePhotos first and accept the dialog" traceback:nil]);
  }

  dispatch_semaphore_t dlSem = dispatch_semaphore_create(0);
  __block NSData *data = nil;
  __block NSError *dlError = nil;
  __block NSHTTPURLResponse *httpResp = nil;
  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
    completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
      data = d;
      dlError = err;
      if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
        httpResp = (NSHTTPURLResponse *)resp;
      }
      dispatch_semaphore_signal(dlSem);
    }];
  [task resume];
  if (dispatch_semaphore_wait(dlSem, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC))) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Download timed out (120s)" traceback:nil]);
  }
  if (dlError || !data || data.length == 0) {
    NSString *msg = dlError ? dlError.localizedDescription : @"Empty response";
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:msg traceback:nil]);
  }
  if (httpResp && httpResp.statusCode >= 400) {
    NSString *msg = [NSString stringWithFormat:@"HTTP %ld", (long)httpResp.statusCode];
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:msg traceback:nil]);
  }

  NSString *ext = [[url pathExtension] lowercaseString];
  BOOL isVideo = [@[@"mp4", @"mov", @"m4v", @"avi", @"3gp"] containsObject:ext];

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
