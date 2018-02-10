//
//  IAPHelper.h
//  IfengNewsFull
//
//  Created by LiXiangming on 16/12/25.
//

#import <Foundation/Foundation.h>


typedef NS_ENUM(NSInteger,IfPurchase_result){
    IfPurchase_sucess = 0,             ///< 购买成功

    IfPurchase_failed_unknow  = -1,     ///< 购买失败，用户还没有花钱的情况(情况比较多,具体的看 SKErrorCode)
    IfPurchase_service_failed = -2,   ///< IFENG 服务器返回 ERROR

    IfPurchase_network_error = 1,      ///< 网络错误
    IfPurchase_id_error = 2,           ///< 商品ID错误，没找到ID
    IfPurchase_canceled = 3,           ///< 取消购买
    IfPurchase_varify_failed = 4,      ///< 用户花钱了但收据验证失败，错误收据
    IfPurchase_payment_unauthorize = 5,///< 没有开启购买权限
    IfPurchase_repeat = 6,             ///< 短时间内重复购买
};

#if !DISABLE_IAP

#import "StoreKit/StoreKit.h"

@interface IAPHelper : NSObject <SKProductsRequestDelegate, SKPaymentTransactionObserver>

SGR_SINGLETION();

/// call this method to remove observer when app terminate
- (void)removeObserverOfTransation;


/*** @param identifier 要购买的物品ID(identifier)
     @param params 传入额外的参数，最后请求服务器进行票据验证的时候传给服务器
     @param callback  IfPurchase_sucess for sucess,other for failed
 **/
- (void)purchaseProductWithIdentifier:(NSString*)identifier
                     withExtranParams:(NSDictionary*)params
                  withCompletionBlock:(void (^)(IfPurchase_result code))callback;
@end

#endif
