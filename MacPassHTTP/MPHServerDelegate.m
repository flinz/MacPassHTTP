//
//  MPHServerDelegate.m
//  MacPassHTTP
//
//  Created by Michael Starke on 13/11/15.
//  Copyright © 2015 HicknHack Software GmbH. All rights reserved.
//

#import "MPHServerDelegate.h"

#import "MPDocument.h"
#import "NSString+MPPasswordCreation.h"
#import "KeePassKit/KeePassKit.h"

static NSUUID *_rootUUID = nil;
static NSString *const _kAESAttributeKey = @"AES key: %@";

@interface MPHServerDelegate ()

@property (weak) MPDocument *queryDocument;
@property (nonatomic, weak) KPKEntry *configurationEntry;
@property (readonly) BOOL queryDocumentOpen;

@end

@implementation MPHServerDelegate

- (instancetype)init {
  self = [super init];
  if(self)
  {
    static const uuid_t uuidBytes = {
      0x34, 0x69, 0x7a, 0x40, 0x8a, 0x5b, 0x41, 0xc0,
      0x9f, 0x36, 0x89, 0x7d, 0x62, 0x3e, 0xcb, 0x31
    };
    _rootUUID = [[NSUUID alloc] initWithUUIDBytes:uuidBytes];
    
  }
  return self;
}

- (void)dealloc {
  NSLog(@"%@ dealloc", [self class]);
}

- (BOOL)queryDocumentOpen {
  [self configurationEntry];
  return self.queryDocument && !self.queryDocument.encrypted;
}

- (KPKEntry *)configurationEntry {
  /* don't return the configurationEntry if it is isn't in the root group, we will move it there first */
  if(_configurationEntry != nil && [_configurationEntry.parent.uuid isEqual:_queryDocument.root.uuid])
    return  _configurationEntry;
  
  NSArray *documents = [[NSDocumentController sharedDocumentController] documents];
  
  MPDocument __weak *lastDocument;
  
  for(MPDocument *document in documents) {
    if(document.encrypted) {
      NSLog(@"Skipping locked Database: %@", [document displayName]);
      /* TODO: Show input window and open db with window */
      continue;
    }
    
    lastDocument = document;
    
    KPKEntry *configEntry = [lastDocument findEntry:_rootUUID];
    if(nil != configEntry) {
      /* if the configEntry is not in the root group then move it there */
      if (![configEntry.parent.uuid isEqual:lastDocument.root.uuid]) {
        /* model updates only on main thread for UI safety */
        dispatch_semaphore_t sema = dispatch_semaphore_create(0L);
        
        dispatch_async(dispatch_get_main_queue(), ^{
          [configEntry moveToGroup:lastDocument.root];
          dispatch_semaphore_signal(sema);
        });
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
      }
      self.configurationEntry = configEntry;
      self.queryDocument = document;
      return _configurationEntry;
    }
  }
  
  if (lastDocument) {
    return [self _createConfigurationEntry:lastDocument];
  }
  
  return nil;
}

- (KPKEntry *)_createConfigurationEntry:(MPDocument *)document {
  KPKEntry *configEntry = [[KPKEntry alloc] initWithUUID:_rootUUID];
  configEntry.title = @"KeePassHttp Settings";
  /* move the entry only on the main thread! */
  dispatch_semaphore_t sema = dispatch_semaphore_create(0L);
  dispatch_async(dispatch_get_main_queue(), ^{
    [document.root addEntry:configEntry];
    dispatch_semaphore_signal(sema);
  });
  dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

  self.configurationEntry = [document findEntry:_rootUUID];
  self.queryDocument = document;
  
  return self.configurationEntry;
}

#pragma mark - KPHDelegate

+ (NSArray *)recursivelyFindEntriesInGroups:(NSArray *)groups forURL:(NSString *)url {
  NSMutableArray *entries = @[].mutableCopy;
  
  for (KPKGroup *group in groups) {
    /* recurse through any subgroups */
    [entries addObjectsFromArray:[self recursivelyFindEntriesInGroups:group.groups forURL:url]];
    
    /* check each entry in the group */
    for (KPKEntry *entry in group.entries) {
      NSString *entryUrl = [entry.url finalValueForEntry:entry];
      NSString *entryTitle = [entry.title finalValueForEntry:entry];
      NSString *entryUsername = [entry.username finalValueForEntry:entry];
      NSString *entryPassword = [entry.password finalValueForEntry:entry];
      
      if (url == nil || [entryTitle rangeOfString:url].length > 0 || [entryUrl rangeOfString:url].length > 0) {
        [entries addObject:[KPHResponseEntry entryWithUrl:entryUrl name:entryTitle login:entryUsername password:entryPassword uuid:[entry.uuid UUIDString] stringFields:nil]];
      }
    }
  }
  
  return entries;
}

- (NSArray *)server:(KPHServer *)server entriesForURL:(NSString *)url {
  if (!self.queryDocumentOpen) {
    return @[];
  }
  
  return [MPHServerDelegate recursivelyFindEntriesInGroups:@[self.queryDocument.root] forURL:url];
}

- (NSString *)server:(KPHServer *)server keyForLabel:(NSString *)label {
  if (!self.queryDocumentOpen) {
    return nil;
  }
  
  return [self.configurationEntry customAttributeForKey:[NSString stringWithFormat:_kAESAttributeKey, label]].value;
}

- (NSString *)server:(KPHServer *)server labelForKey:(NSString *)key {
  if (!self.queryDocumentOpen) {
    return nil;
  }
  
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"MacPassHTTP";
  NSBundle *bundle = [NSBundle bundleForClass:[self class]];
  NSString *message = NSLocalizedStringFromTableInBundle(@"dialog.request_access.message_%@", @"", bundle, @"Message shown when a new KeePassHTTP Client want's access to the database");
  alert.informativeText = [NSString stringWithFormat:message, key];
  alert.alertStyle = NSWarningAlertStyle;
  [alert addButtonWithTitle:NSLocalizedStringFromTableInBundle(@"dialog.request_access.allow_button", @"", bundle, @"Allow acces to Database")];
  [alert addButtonWithTitle:NSLocalizedStringFromTableInBundle(@"dialog.request_access.deny_button", @"", bundle, @"Deny acces to database")];
  
  NSString __block *label = nil;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0L);
  
  dispatch_async(dispatch_get_main_queue(), ^{
    NSInteger ret = [alert runModal];
    if(ret == NSAlertFirstButtonReturn) {
      label = [NSString passwordWithCharactersets:MPPasswordCharactersLowerCase withCustomCharacters:nil length:16];
      [self.configurationEntry addCustomAttribute:[[KPKAttribute alloc] initWithKey:[NSString stringWithFormat:_kAESAttributeKey, label] value:key]];
    }
    dispatch_semaphore_signal(sema);
  });
  
  dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
  
  return label;
}

- (void)server:(KPHServer *)server setUsername:(NSString *)username andPassword:(NSString *)password forURL:(NSString *)url withUUID:(NSString *)uuid {
  if (!self.queryDocumentOpen) {
    return;
  }
  /* creat entry on main thread */
  __weak MPHServerDelegate *welf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    KPKEntry *entry = uuid ? [welf.queryDocument findEntry:[[NSUUID alloc] initWithUUIDString:uuid]] : nil;
    
    if (!entry) {
      entry = [[KPKEntry alloc] init];
      [welf.queryDocument.root addEntry:entry];
    }
    entry.title = url;
    entry.username = username;
    entry.password = password;
    entry.url = url;
  });
  
}

- (NSArray *)allEntriesForServer:(KPHServer *)server {
  if (!self.queryDocumentOpen) {
    return @[];
  }
  
  return [MPHServerDelegate recursivelyFindEntriesInGroups:self.queryDocument.root.groups forURL:nil];
}

- (NSString *)generatePasswordForServer:(KPHServer *)server {
  return [NSString passwordWithDefaultSettings];
}

- (NSString *)clientHashForServer:(KPHServer *)server {
  if (!self.queryDocumentOpen) {
    return nil;
  }
  
  return [NSString stringWithFormat:@"%@%@", self.queryDocument.root.uuid.UUIDString, self.queryDocument.trash.uuid.UUIDString];
}

@end
