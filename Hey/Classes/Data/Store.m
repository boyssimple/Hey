//
//  Store.m
//  Hey
//
//  Created by Ascen on 2017/4/19.
//  Copyright © 2017年 Ascen. All rights reserved.
//

#import "Store.h"
#import "AccessTokenStore.h"
#import "DBMigrationHelper.h"
#import <FMDB/FMDB.h>
#import <MTLFMDBAdapter/MTLFMDBAdapter.h>

@interface Store ()

@property (nonatomic, strong) FMDatabase *db;

@property (nonatomic, strong) RACSubject *subject;

@end

@implementation Store

+ (instancetype)sharedStore {
    static dispatch_once_t onceToken;
    static Store *store;
    dispatch_once(&onceToken, ^{
        store = [[Store alloc] init];
    });
    return store;
}

- (instancetype)init {
    if (self = [super init]) {
        _subject = [RACSubject subject];
        _stateSignal = [[[[_subject scanWithStart:[self initialState] reduce:^State *(State *state, ReduceBlock reduceBlock) {
            return reduceBlock(state);
        }]
                          startWith:[self initialState]]
                         subscribeOn:[RACScheduler scheduler]]
                        replayLast];
        
        _viewerSignal = [[_stateSignal map:^id(State *state) {
            return state.viewer;
        }] distinctUntilChanged];
        
        _tokenSignal = [[_viewerSignal map:^id(Viewer *viewer) {
            return viewer.token;
        }] distinctUntilChanged];
        
        _userSignal = [[_viewerSignal map:^id(Viewer *viewer) {
            return viewer.user;
        }] distinctUntilChanged];
        
        _chatRecordSignal = [[_viewerSignal map:^id(Viewer *viewer) {
            return viewer.chatRecords;
        }] distinctUntilChanged];
        
        _chatSessionSignal = [[_viewerSignal map:^id(Viewer *viewer) {
            return viewer.chatSessions;
        }] distinctUntilChanged];
        
#ifdef DEBUG
        [_stateSignal subscribeNext:^(State *state) {
            NSError *error;
            NSDictionary *json = [MTLJSONAdapter JSONDictionaryFromModel:state error:&error];
            if (error) {
                NSLog(@"app state %@", error);
            } else {
                NSLog(@"app state = %@", json);
            }
        }];
#endif
    }
    return self;
}

#pragma mark - Update

- (void)updateToken:(NSString *)token {
    [self updateState:^State *(State *state) {
        Viewer *viewer = [Viewer createWithViewer:state.viewer key:@"token" value:token];
        [self persistViewer:viewer];
        return [State createWithState:state key:@"viewer" value:viewer];
    }];
}

- (void)updateState:(ReduceBlock)reduceBlock {
    [self.subject sendNext:reduceBlock];
}

- (void)updateViewer:(Viewer *)viewer {
    [self updateState:^State *(State *state) {
        return [State createWithState:state key:@"viewer" value:viewer];
    }];
}

- (void)updateUser:(User *)user {
    [self updateState:^State *(State *state) {
        Viewer *viewer = [Viewer createWithViewer:state.viewer key:@"user" value:user];
        [self persistViewer:viewer];
        return [State createWithState:state key:@"viewer" value:viewer];
    }];
}

- (void)updateSession:(NSArray *)sessions {
    [self updateState:^State *(State *state) {
        Viewer *viewer = [Viewer createWithViewer:state.viewer key:@"chatSessions" value:sessions];
        [self persistViewer:viewer];
        return [State createWithState:state key:@"viewer" value:viewer];
    }];
}

- (void)updateChatRecords:(NSArray *)chatRecords {
    [self updateState:^State *(State *state) {
        Viewer *viewer = [Viewer createWithViewer:state.viewer key:@"chatRecords" value:chatRecords];
        [self persistViewer:viewer];
        return [State createWithState:state key:@"viewer" value:viewer];
    }];
}

- (void)clearViewer {
    [self updateState:^State *(State *state) {
        [self persistViewer:nil];
        return [State createWithState:state key:@"viewer" value:nil];
    }];
}

#pragma mark - Init

- (void)persistViewer:(Viewer *)viewer {
    
    [self.db executeUpdate:@"DELETE FROM t_users"];
    
    [[AccessTokenStore sharedStore] clearToken];
    if (viewer.user) {
        NSString *insertUser = [MTLFMDBAdapter insertStatementForModel:viewer.user];
        [self.db executeUpdate:insertUser];
//        NSString *insertUser = @"insert into t_users (identity, avatar, name) values (?, ?, ?)";
//        [self.db executeUpdate:insertUser, viewer.user.Id, viewer.user.avatar, viewer.user.name];
    }
    
    if (viewer.chatSessions) {
//        NSString *storeChatSessions = @"insert into t_chat_sessions (identity, avatar, name) values (?, ?, ?)";
        /*
         @property (nonatomic, strong) NSNumber *Id;
         @property (nonatomic, copy) NSArray *userIds;
         @property (nonatomic, strong) NSData *userIdsData;
         @property (nonatomic, copy) NSString *username;
         @property (nonatomic, copy) NSString *iconURL;
         @property (nonatomic, copy) NSString *sessionName;
         @property (nonatomic, copy) NSString *lastSentence;
         @property (nonatomic, strong) NSDate *time;
         */
//        for (int i = 0; i < viewer.chatSessions.count; ++i) {
//            ChatSession *session = viewer.chatSessions[i];
//            [self.db executeUpdate:storeChatSessions, session.Id, session.userIdsData, session.username, session.iconURL, session.sessionName, session.lastSentence, ];
//        }
    }
    
    if (viewer.token) {
        [[AccessTokenStore sharedStore] updateToken:viewer.token];
    }
}

- (State *)initialState {
    Viewer *viewer = [self viewerFromDB];
//    NSString *username = [[NSUserDefaults standardUserDefaults] stringForKey:@"username"];
    return [[State alloc] initWithDictionary:@{
                                               @"viewer" : viewer ?: NSNull.null,
                                               } error:NULL];
}

- (Viewer *)viewerFromDB {
    NSString *token = [[AccessTokenStore sharedStore] getToken];
    if (!token) {
        return nil;
    }
    
    NSError *error;
    FMResultSet *resultSet = [self.db executeQuery:@"SELECT * FROM t_users LIMIT 1"];
    User *user;
    if ([resultSet next]) {
        user = [MTLFMDBAdapter modelOfClass:[User class] fromFMResultSet:resultSet error:&error];
    }
    
    if (!user) {
        if (error) {
            NSLog(@"%@", error);
        }
        return nil;
    }
    
    Viewer *viewer = [[Viewer alloc] initWithDictionary:@{
                                                          @"token" : token,
                                                          @"user" : user,
                                                          } error:&error];
    if (error) {
        NSLog(@"%@", error);
    }
    
    return viewer;
}

- (FMDatabase *)db {
    if (!_db) {
        _db = [DBMigrationHelper sharedInstance].database;
    }
    return _db;
}
@end