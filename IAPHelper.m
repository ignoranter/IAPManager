//
//  IAPHelper.m
//  IfengNewsFull
//
//  Created by LiXiangming on 16/12/25.
//

#if !DISABLE_IAP

#import "IAPHelper.h"
#import "NSString+Base64.h"
#import "IFHTTPManager+Project.h"
#import "IfengSystemInfo.h"
#import "IfengUILabel.h"
#import "MBProgressHUD.h"
#import "CKHeader.h"
#import "IFThreadSafeCollection.h"



#define DeviceToken @"device"
#define ReceiptDataKey @"receipt"
#define ExtraneousParams @"ExtraneousParams"
#define SKProductIdentifierKey @"SKProductIdentifier"



typedef void (^IAPProductsResponseBlock)   (SKProductsRequest* request, SKProductsResponse* response);
typedef void (^IAPbuyProductCompleteResponseBlock)(SKPaymentTransaction* transcation);
typedef void (^checkReceiptCompleteResponseBlock)(NSString* response,NSError* error);

NSString * const kIfengProductPurchasedNotification = @"com.xominlee.ifengnews.productspurchased";
NSString * const kIfengProductPurchaseFailedNotification =
            @"com.xominlee.ifengnews.productspurchasefailed";

@interface IAPHelper()

@property (nonatomic,  copy) IAPProductsResponseBlock requestProductsBlock;

@property (nonatomic,  copy) IAPbuyProductCompleteResponseBlock buyProductCompleteBlock;

@property (nonatomic,  copy) checkReceiptCompleteResponseBlock checkReceiptCompleteBlock;

@property (nonatomic,strong) NSMutableData* receiptRequestData;

@property (readwrite, nonatomic, strong) SKProductsRequest *request;

@property (readwrite, nonatomic, strong) IFThreadSafeDictionary* purchaseRecord;

@property (nonatomic, strong) IFThreadSafeDictionary* uploadingRecord;

@property (nonatomic) bool needReupload;

@end


@implementation IAPHelper{
    MBProgressHUD* _HUD;
}

static void inline showAlertView(NSString* title,NSString* msg){

    UIAlertController *controller = [UIAlertController alertControllerWithTitle: NSLocalizedString(title,nil)                message:NSLocalizedString(msg,nil) preferredStyle:UIAlertControllerStyleAlert];
                                    [controller addAction:
    [UIAlertAction actionWithTitle:@"确定"style:UIAlertActionStyleCancel handler: nil]];
    [[UIApplication sharedApplication].keyWindow.rootViewController
     presentViewController:controller animated:YES completion:nil];
}

static NSData* recieptDataformAppleService(){

    NSURL *receiptURL = [[NSBundle mainBundle] appStoreReceiptURL];
    NSError *receiptError;
    BOOL isPresent = [receiptURL checkResourceIsReachableAndReturnError:&receiptError];
    if (!isPresent) {
        /// No receipt - In App Purchase was never initiated
        DDLogDebug(@"ERROR:%@",receiptError);
        return nil;
    }
    return [NSData dataWithContentsOfURL:receiptURL];
}

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static IAPHelper* instance;
    dispatch_once(&once,^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (void)dealloc{
    [self removeObserverOfTransation];
    [NotificationCenter removeObserver:self];
}

- (instancetype)init{
    if (self = [super init]) {
        _uploadingRecord = [IFThreadSafeDictionary new];
        [self restorePurchaseRecord];
        if ([SKPaymentQueue defaultQueue]) {
            [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
        }
        dispatch_delay_on_main_queue(5, ^(void){
            self.needReupload = _purchaseRecord.count > 0;
            if (self.needReupload) {
                [self uploadPendingPurchase];
            }
        });
    }
    return self;
}

- (void)upgradeCompatibleCheck {
#if ClientType == 0
    if (IS_UPGRADE_APP) {
        // upgrade from 5.5.2
        NSArray* directoryURLs = [FileManager contentsOfDirectoryAtURL:[FileManager URLForUserDirectory:NSDocumentDirectory]
            includingPropertiesForKeys:nil options:0 error:nil];
        NSMutableArray* pendingItems = [NSMutableArray new];
        for (NSURL* element in directoryURLs){
            NSString* lastPath = [element lastPathComponent];
            if ([lastPath hasPrefix:@"charge_"]) {
                NSString* guid = [lastPath substringFromIndex:[@"charge_" length]];
                NSDictionary* pending_IAP = [NSKeyedUnarchiver unarchiveObjectWithFile:element.path];
                [pendingItems addObject:@[element, guid, pending_IAP]];
            }
        }
        if (pendingItems.count > 0) {
            NSString* deviceID = [self __userId];
            [_purchaseRecord performLockedWithDictionary:^(NSMutableDictionary* _Nonnull dictionary){
                for (NSArray* element in pendingItems){
                    NSString* guid = element[1];
                    NSDictionary* pending_IAP = element[2];
                    [pending_IAP enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop){
                        NSMutableDictionary* d = [NSMutableDictionary new];
                        d[ReceiptDataKey] = obj;
                        // old user shouldn't have device data. ignore it and use current user
                        if (IS_NONNULL_STRING(guid) && ![guid isEqual:deviceID]) {
                            d[@"guid"] = guid;
                        }
                        dictionary[key] = d;
                    }];
                }
            }];
            [self savePurchaseRecord];
            for (NSArray* element in pendingItems){
                [FileManager removeItemAtURL:element[0] error:nil];
            }
        }
    }
#endif
}

/// get purchased record
- (void)restorePurchaseRecord {
    NSDictionary* purchased = [NSKeyedUnarchiver unarchiveObjectWithFile:[self purchaseRecordFilePath]];
    if (purchased.count > 0) {
        if (IS_CLASS(purchased, IFThreadSafeDictionary)) {
            self.purchaseRecord = (id)purchased;
        } else {
            self.purchaseRecord = [IFThreadSafeDictionary dictionaryWithDictionary:purchased];
        }
    } else {
        self.purchaseRecord = [IFThreadSafeDictionary new];
    }
    [self upgradeCompatibleCheck];
    DDLogDebug(@"self.purchaseRecord count:%ld", (unsigned long)self.purchaseRecord.count);
}

/// write  purchased record to file
- (void)savePurchaseRecord {
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self.purchaseRecord];

    BOOL success = [data writeToFile:[self purchaseRecordFilePath] options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:&error];
    NSParameterAssert(success);

    if (!success) {
        DDLogWarn(@"Failed to remember data record: %@", error);
    }
}

- (void)setNeedReupload:(bool)needReupload {
    if (needReupload != _needReupload) {
        _needReupload = needReupload;
        if (needReupload) {
            [[NSNotificationCenter defaultCenter] addObserver: self
                                                     selector: @selector(uploadPendingPurchase)
                                                         name: UIApplicationWillEnterForegroundNotification
                                                       object: nil];
            // when loginin, may upload device receipt. which don't allow anonymous
            [[NSNotificationCenter defaultCenter] addObserver: self
                                                     selector: @selector(uploadPendingPurchase)
                                                         name: IFLoginNotification
                                                       object: nil];
            [self startObservingReachabilityChange:^(IAPHelper*  _Nonnull self, AFNetworkReachabilityStatus oldStatus, AFNetworkReachabilityStatus newStatus){
                if (newStatus != oldStatus && newStatus != AFNetworkReachabilityStatusNotReachable) {
                    [self uploadPendingPurchase];
                }
            }];
        } else {
            [NotificationCenter removeObserver:self];
            [self stopObservingReachabilityChange];
        }
    }
}

- (NSString *)purchaseRecordFilePath {
    NSString *documentDirectory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                      NSUserDomainMask, YES).firstObject;

    return [documentDirectory stringByAppendingPathComponent:@"pending_IAP"];
}

- (void)removeObserverOfTransation{
    if ([SKPaymentQueue defaultQueue]) {
        [[SKPaymentQueue defaultQueue] removeTransactionObserver:self];
    }
}

- (void)requestWithIdentifiers:(NSSet *)productIdentifiers
              withExtranParams:(NSDictionary*)params
                WithCompletion:(IAPProductsResponseBlock)completion {

    self.request = [[SKProductsRequest alloc] initWithProductIdentifiers:productIdentifiers];
    _request.delegate = self;
    self.requestProductsBlock = completion;

    [_request start];
}

- (void)purchaseProductWithIdentifier:(NSString*)identifier
                     withExtranParams:(NSDictionary*)params
                 withCompletionBlock:(void (^)(IfPurchase_result code))callback{

  dispatch_on_main_queue(^(void){
    if (![SKPaymentQueue canMakePayments]){
        showAlertView(@"提示", @"您手机未打开应用内购买权限，请到设置页更改然后重试！");
        if (callback) { callback( IfPurchase_payment_unauthorize ); }
        return;
    }

    if (IS_NULL_STRING(identifier)) {
        if (callback) { callback( IfPurchase_id_error); }
        return;
    }

    if (![self showIndicatorView]) {
        if (callback) { callback( IfPurchase_repeat ); }
        return;
    }

    void(^completionBlock)(IfPurchase_result) = ^(IfPurchase_result code) {
        dispatch_on_main_queue(^(void){
            [self hideIndicatorView];
            if (callback) { callback(code); }
        });
    };

    [self requestWithIdentifiers:[NSSet setWithObject:identifier]
                withExtranParams:params
                  WithCompletion:^(SKProductsRequest *request, SKProductsResponse *response)
      {
            if(response && response != nil ) {

                if (response.products.count){
                    SKPaymentTransaction* current = [self transactionForProductID:identifier];
                    /// 如果未完成, 苹果会提示恢复, 但是没任何回调, 所以支付前先判断相关的transaction是不是已经存在了, 并做相应的重试操作
                    if (current && current.transactionState == SKPaymentTransactionStatePurchased) {
                        NSDictionary* receipt = self.purchaseRecord[current.transactionIdentifier];
                        if (!receipt) {
                            // 这可能是多线程导致之前的重试正好成功了.  也可能出bug, purchaseRecord里没加到这条payment, 按错误处理
                            completionBlock(IfPurchase_network_error);
                        } else {
                            dispatch_on_main_queue(^{
                                _HUD.margin = 20;
                                _HUD.labelText = @"您已购买该项目, 正在为您恢复";
                            });
                            [self postCertifiertoVarify:receipt withTransactionIdentifier:current.transactionIdentifier onCompletion:^(IfPurchase_result recivedCode){
                                completionBlock( recivedCode);
                            }];
                        }
                    } else {
                        [self buyProduct:response.products[0] withExtranParams:params
                            onCompletion:^(SKPaymentTransaction* trans){
                            if(trans.error){
                                DDLogDebug(@"Fail %@",[trans.error localizedDescription]);
                                if (trans.error.code == SKErrorPaymentCancelled) {
                                    completionBlock(IfPurchase_canceled);
                                } else {
                                    completionBlock(IfPurchase_failed_unknow);
                                }
                            }
                            else if (trans.transactionState == SKPaymentTransactionStatePurchased){

                                /// post certificate to service to Varify
                                [self postCertifiertoVarify:self.purchaseRecord[trans.transactionIdentifier] withTransactionIdentifier:trans.transactionIdentifier onCompletion:^(IfPurchase_result recivedCode)
                                {
                                    completionBlock( recivedCode );
                                }];
                                DDLogDebug(@"PURCHASE SUCESSED !!!");
                            }else{
                                completionBlock(IfPurchase_failed_unknow);
                                DDLogDebug(@"PURCHASE STATE %d", (int)trans.transactionState);
                            }
                        }];
                    }
                }else{
                    NSParameterAssert(NO);
                    completionBlock(IfPurchase_failed_unknow);
                    DDLogDebug(@"CAN'T GET PRODUCT INFO !!!");
                }
            }else{
                completionBlock( IfPurchase_failed_unknow );
            }
        }];

  });
}

- (BOOL)uploadPendingPurchase {
    NSArray*recordReciepts =  [_purchaseRecord allKeys];
    if (recordReciepts.count == 0) { return true; }
    TagLogInfo(IAP, @"upload pending(%lu) purchase", (unsigned long)recordReciepts.count);
    [recordReciepts enumerateObjectsUsingBlock:^(NSString*  _Nonnull receiptkey, NSUInteger idx, BOOL * _Nonnull stop) {
        NSDictionary* receipt = [_purchaseRecord dictForKey:receiptkey];
        if (receipt) {
            [self postCertifiertoVarify:receipt withTransactionIdentifier:receiptkey onCompletion:nil];
        }
    }];
    return false;
}

- (BOOL)showIndicatorView{
    if (_HUD) { return false; }

    _HUD = [MBProgressHUD showHUDAddedTo:
            [UIApplication sharedApplication].keyWindow.rootViewController.view.window animated:YES];
    _HUD.margin = 20;
    _HUD.yOffset = SCREEN_HEIGHT/2-IFScreenFit2(320,380);
    _HUD.cornerRadius = 5.0;

    return true;
}

- (void)hideIndicatorView{
    dispatch_async(dispatch_get_main_queue(), ^{
        [_HUD hide:YES];
        _HUD = nil;
    });
}

#pragma mark SKProductsRequest delegate
- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {

    self.request = nil;

    if(_requestProductsBlock) {
        _requestProductsBlock (request,response);
        _requestProductsBlock = nil;
    }
}

- (void)postCertifiertoVarify :(NSDictionary*)receipt withTransactionIdentifier:(NSString*)transactionIdentifier
                  onCompletion:(void (^)(IfPurchase_result recivedCode)) completionBlock
{
    NSParameterAssert(IS_CLASS(receipt, NSDictionary));
    NSData* receiptData = [receipt objOfType:[NSData class] forKey:ReceiptDataKey];
    NSDictionary *paramsDic = [receipt objOfType:NSDictionary.class forKey:ExtraneousParams];
    NSParameterAssert(receiptData);

    if (IS_NULL_STRING(transactionIdentifier) || !receiptData) {
        if (completionBlock) { completionBlock(IfPurchase_id_error); }
        return;
    }

    NSMutableDictionary* uploading = [_uploadingRecord lock];
    NSMutableArray* otherCompletionCallbacks = uploading[transactionIdentifier];
    if (otherCompletionCallbacks) { // alread uploading
        [otherCompletionCallbacks add:completionBlock];
        [_uploadingRecord unlock];
        return;
    } else {
        uploading[transactionIdentifier] = [NSMutableArray new];
    }
    [_uploadingRecord unlock];

    completionBlock = ^(IfPurchase_result recivedCode) {
        if (completionBlock) { completionBlock(recivedCode); }

        // pop fhs transactionIdentifier waiting callbacks
        NSMutableDictionary* uploading = [_uploadingRecord lock];
        NSArray* otherCompletionCallbacks = uploading[transactionIdentifier];
        [uploading removeObjectForKey:transactionIdentifier];
        [_uploadingRecord unlock];

        for ( void(^element)(NSInteger) in otherCompletionCallbacks){
            element(recivedCode);
        }
    };

    NSString* checkRecieptURL = WEB_API(@"PayVerify");
    checkRecieptURL = [self URLStringByStandardizingURL:checkRecieptURL];
    NSString *guid = receipt[@"guid"], *token = receipt[@"token"];
    if ( IS_NULL_STRING(guid) ) {
        UCUserEntity* user = [Globle sharedInstance].userEntity;
        guid = user.userGUID; token = user.userToken;
    }
    if (IS_NONNULL_STRING(guid) && ![guid isEqual:DeviceToken]) {
        // if is current user, use current token, because it may update
        if ([guid isEqual:[Globle sharedInstance].userEntity.userGUID]) { token = [Globle sharedInstance].userEntity.userToken; }
        if (token) { checkRecieptURL = [checkRecieptURL stringByAppendingFormat:@"&guid=%@&token=%@", guid.URLEncodedString, token.URLEncodedString]; }
        else { checkRecieptURL = [checkRecieptURL stringByAppendingFormat:@"&guid=%@", guid.URLEncodedString]; }
    }

    NSString *receiptBase64 = [NSString base64StringFromData:receiptData length:[receiptData length]];
    NSMutableDictionary *receiptDic = [NSMutableDictionary dictionaryWithObjectsAndKeys:receiptBase64,@"apple_receipt",nil];
    if (paramsDic.count > 0) {
        [receiptDic addEntriesFromDictionary:paramsDic];
    }
    [receiptDic set:transactionIdentifier forKey:@"IAPTransactionIdentifier"];
    [receiptDic set:receipt[SKProductIdentifierKey] forKey:@"IAPProductIdentifier"];

    WEAKIFY(self);
    IFJSONRequest* request = [IFJSONRequest newWithURL:checkRecieptURL
                                            parameters:receiptDic
        complete:^(NSURLResponse * _Nullable response, id  _Nullable responseObject, NSError * _Nullable error)
    {
        STRONGIFY_OR_RET(self);
              if (error) {
                  DDLogDebug(@"ERROR:%ld description: %@",(long)error.code,error.description);
                  dispatch_async(dispatch_get_main_queue(), ^{
                      completionBlock(IfPurchase_service_failed);
                  });

                  return;
              }
              NSDictionary *jsonResponse = DYNAMIC_CAST(responseObject, NSDictionary);
              NSInteger status = [jsonResponse integerForKey:@"code" def:-1];

              NSParameterAssert(jsonResponse);
              if (nil == jsonResponse) {
                  //upload failed
                  dispatch_async(dispatch_get_main_queue(), ^{
                      completionBlock(IfPurchase_service_failed);
                  });
                  return;
              }
              // 200: OK
              // 5025: 重复单据
             IfPurchase_result result_code;
              if (200 == status || 5025 == status) {
                  result_code = IfPurchase_sucess;
                 [self finishTransactionAndDeleteRecord:YES
                               withTransactionIdentifer:transactionIdentifier];
              }else{
                  result_code = IfPurchase_varify_failed;
              }
              // no resave while sucess or certificate is verified wrong by service
              dispatch_async(dispatch_get_main_queue(), ^{
                  completionBlock(result_code);
              });
      }];

    request.appendStandardParams = NO;
    [request POST];
}

- (void)buyProduct:(SKProduct *)productIdentifier withExtranParams:(NSDictionary*)params
      onCompletion:(IAPbuyProductCompleteResponseBlock)completion {
    NSParameterAssert(productIdentifier);

    if (nil != completion) {
        self.buyProductCompleteBlock = completion;
    }
    if (nil == params) {
        params = NSDictionary.new;
    }

    SKMutablePayment *payment = [SKMutablePayment paymentWithProduct:productIdentifier];
    UCUserEntity* entity = [Globle sharedInstance].userEntity;
    if (entity) {
        payment.applicationUsername = [@{         @"guid" : SAFE_STRING(entity.userGUID),
                                                 @"token" : SAFE_STRING(entity.userToken),
                                         ExtraneousParams : params
                                         } JSONRepresentation];
    } else {
        payment.applicationUsername = [@{         @"guid" : DeviceToken,
                                         ExtraneousParams : params
                                         } JSONRepresentation];
    }

    if ([SKPaymentQueue defaultQueue]) {
        [[SKPaymentQueue defaultQueue] addPayment:payment];
    }
}

- (void)completeTransactionAndSaveRecord:(SKPaymentTransaction *)transaction {

    if ( transaction.transactionState == SKPaymentTransactionStatePurchased ) {
        NSData *receiptData = recieptDataformAppleService();
        if (nil != receiptData) {
            NSString* user = transaction.payment.applicationUsername;
            NSString *guid = nil, *token = nil;
            NSDictionary *paramsDic = nil;
            if (IS_NONNULL_STRING(user)) {
                NSDictionary* userData = [user JSONValue];
                if (IS_CLASS(userData, NSDictionary)) {
                    guid      = [userData strForKey:@"guid"];
                    token     = [userData strForKey:@"token"];
                    paramsDic = [userData dictForKey:ExtraneousParams];
                }
            }

            NSMutableDictionary* receipt = [NSMutableDictionary new];
            receipt[ReceiptDataKey] = receiptData;
            if (IS_NONNULL_STRING(guid)) {
                receipt[@"guid"] = guid;
                [receipt set:token forKey:@"token"];
                [receipt set:paramsDic forKey:ExtraneousParams];
            }
            [receipt set:transaction.payment.productIdentifier forKey:SKProductIdentifierKey];

            [_purchaseRecord performLockedWithDictionary:^(NSMutableDictionary * _Nonnull dictionary){
                NSUInteger oldCount = dictionary.count;
                dictionary[transaction.transactionIdentifier] = receipt.copy;
                if (oldCount == 0 ) {
                    self.needReupload = true;
                }
            }];

            DDLogDebug(@"COMPLETION: self.purchaseRecord: %lu",(unsigned long)self.purchaseRecord.count);
            [self savePurchaseRecord];
        }

    }
}

- (SKPaymentTransaction*)transactionForIdentifier:(NSString*)transactionIdentifier {
    if (IS_NULL_STRING(transactionIdentifier)) { return nil; }
    for (SKPaymentTransaction* element in [[SKPaymentQueue defaultQueue] transactions]){
        if ([element.transactionIdentifier isEqual: transactionIdentifier]) {
            return element;
        }
    }
    return nil;
}

- (SKPaymentTransaction*)transactionForProductID:(NSString*)productID {
    for (SKPaymentTransaction* element in [[SKPaymentQueue defaultQueue] transactions]){
        if ( [element.payment.productIdentifier isEqual:productID] ) {
            return element;
        }
    }
    return nil;
}

- (void)finishTransactionAndDeleteRecord:(BOOL)finish
                           withTransactionIdentifer:(NSString*)transactionIdentifier{
    /** trasfer sucess,delete the varified certificate */
    if (transactionIdentifier) {
        if (YES == finish)
        {
            [_purchaseRecord performLockedWithDictionary:^(NSMutableDictionary* _Nonnull dictionary){
                SKPaymentTransaction* transaction = [self transactionForIdentifier:transactionIdentifier];
                if (transaction) { [[SKPaymentQueue defaultQueue] finishTransaction:transaction]; }
                [dictionary removeObjectForKey:transactionIdentifier];
            }];

            // write to disk
            [self savePurchaseRecord];
            if (_purchaseRecord.count == 0) {
                self.needReupload = false;
            }
            DDLogDebug(@"AFTER DELETE| self.purchaseRecord.count: %lu",(unsigned long)self.purchaseRecord.count);
        }
    }
}

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions
{
    for (SKPaymentTransaction *transaction in transactions){
        switch (transaction.transactionState)
        {
            case SKPaymentTransactionStatePurchased:{
                /// save the product info, this may be called when upload server fail, and apple call it when relaunch.
                [self completeTransactionAndSaveRecord:transaction];

                [[NSNotificationCenter defaultCenter] postNotificationName:
                 kIfengProductPurchasedNotification object:transaction];

                if(_buyProductCompleteBlock) {
                    _buyProductCompleteBlock(transaction);
                    _buyProductCompleteBlock = nil;
                } else { // apple relaunch the payment
                    // apple background restore complete
                    // comment out this to debug fail and restart
#if defined(DEBUG) && DEBUG != 0
                    [_purchaseRecord removeObjectForKey:transaction.transactionIdentifier];
                    [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
#else
                    [self postCertifiertoVarify:self.purchaseRecord[transaction.transactionIdentifier] withTransactionIdentifier:transaction.transactionIdentifier onCompletion:^(NSInteger recivedCode)
                    {}];
#endif
                }
            }
                break;
            case SKPaymentTransactionStateFailed:{
                [[NSNotificationCenter defaultCenter] postNotificationName:kIfengProductPurchaseFailedNotification object:transaction];

                [self failedTransaction:transaction];
            }
                break;
            case SKPaymentTransactionStatePurchasing:
                DDLogDebug(@"%@ is being processed by the App Store...",
                           transaction.payment.productIdentifier);
                break;
            case SKPaymentTransactionStateDeferred:{
                // FIXME: 这种延迟状态好像没什么好的处理方法?
                DDLogDebug(@"ERROR: The transaction is in the queue,\
                           but its final status is pending external action");
                [self hideIndicatorView];
            }
                break;
            default:
                DDLogDebug(@"ERROR: should enter this, state %ld", (long)transaction.transactionState);
                break;
        }
    }
}

- (void)failedTransaction:(SKPaymentTransaction *)transaction {

    switch (transaction.error.code) {
        case SKErrorPaymentNotAllowed:
            DDLogDebug(@"this device is not allowed to make the payment");
            break;
        case SKErrorCloudServicePermissionDenied:
            DDLogDebug(@"you has not allowed access to cloud service information");
            break;
        case SKErrorCloudServiceNetworkConnectionFailed:
            DDLogDebug(@"the device could not connect to the nework");
            break;
        case SKErrorPaymentCancelled:
            DDLogDebug(@"user cancelled");
            break;
        case SKErrorUnknown:{
            DDLogDebug(@"maybe is escape device");
        }
            break;
        case SKErrorClientInvalid:
            break;
        default:
            break;
    }
    DDLogDebug(@"Transaction error: %@ %ld",
               transaction.error.localizedDescription,(long)transaction.error.code);

    if ([SKPaymentQueue defaultQueue]) {
        [[SKPaymentQueue defaultQueue] finishTransaction: transaction];
    }
    if(_buyProductCompleteBlock) {
        _buyProductCompleteBlock(transaction);
        _buyProductCompleteBlock = nil;
    }
}

- (NSString*)URLStringByStandardizingURL:(NSString*)oldURL {
    NSParameterAssert(IS_NONNULL_STRING(oldURL));
    if (IS_NULL_STRING(oldURL)){ return nil; }

    NSString* queryParam =
    [NSString stringWithFormat:@"deviceid=%@&gv=%@&av=%@&proid=%@&os=%@&vt=%@&screen=%@&publishid=%@&uid=%@&nw=%@",
     [self __userId], APP_VERSION, @"0", COMIFENG_PRODUCTNAME, [IfengSystemInfo os], @"5",
     [IfengSystemInfo screenSize], [self __publishId], [IfengSystemInfo userId], [IfengSystemInfo net]];
    return [oldURL stringByAppendingQueryString:queryParam];
}

@end

#endif
