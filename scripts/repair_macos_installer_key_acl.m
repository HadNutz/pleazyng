#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>

static int fail(const char *operation, OSStatus status) {
    fprintf(stderr, "%s failed (OSStatus %d)\n", operation, (int)status);
    return 2;
}

static NSString *certificateSHA1(SecCertificateRef certificate) {
    CFDataRef der = SecCertificateCopyData(certificate);
    if (der == NULL) return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(CFDataGetBytePtr(der), (CC_LONG)CFDataGetLength(der), digest);
    CFRelease(der);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA1_DIGEST_LENGTH; ++index) {
        [result appendFormat:@"%02X", digest[index]];
    }
    return result;
}

static BOOL isSigningACL(SecACLRef acl, OSStatus *status) {
    CFArrayRef authorizations = SecACLCopyAuthorizations(acl);
    if (authorizations == NULL) {
        *status = errSecInternalComponent;
        return NO;
    }
    BOOL matches = NO;
    for (CFIndex index = 0; index < CFArrayGetCount(authorizations); ++index) {
        CFTypeRef value = CFArrayGetValueAtIndex(authorizations, index);
        if (CFGetTypeID(value) == CFStringGetTypeID() &&
            CFStringCompare((CFStringRef)value, CFSTR("sign"), 0) == kCFCompareEqualTo) {
            matches = YES;
            break;
        }
    }
    CFRelease(authorizations);
    return matches;
}

static BOOL containsTrustedApplication(CFArrayRef applications, CFDataRef wantedData,
                                       OSStatus *status) {
    if (applications == NULL) return YES;
    for (CFIndex index = 0; index < CFArrayGetCount(applications); ++index) {
        CFTypeRef value = CFArrayGetValueAtIndex(applications, index);
        if (CFGetTypeID(value) != SecTrustedApplicationGetTypeID()) continue;
        CFDataRef data = NULL;
        *status = SecTrustedApplicationCopyData((SecTrustedApplicationRef)value, &data);
        if (*status != errSecSuccess) return NO;
        BOOL matches = CFEqual(data, wantedData);
        CFRelease(data);
        if (matches) return YES;
    }
    return NO;
}

static int repair(SecKeychainRef keychain, NSString *expectedSHA1) {
    NSDictionary *identityQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassIdentity,
        (__bridge id)kSecUseKeychain: (__bridge id)keychain,
        (__bridge id)kSecReturnRef: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
    };
    CFTypeRef identityResult = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)identityQuery, &identityResult);
    if (status != errSecSuccess) return fail("find installer identity", status);
    NSArray *identities = CFGetTypeID(identityResult) == CFArrayGetTypeID()
        ? (__bridge NSArray *)identityResult : @[(__bridge id)identityResult];
    SecIdentityRef selectedIdentity = NULL;
    NSUInteger matches = 0;
    for (id value in identities) {
        SecCertificateRef certificate = NULL;
        status = SecIdentityCopyCertificate((__bridge SecIdentityRef)value, &certificate);
        if (status != errSecSuccess) {
            CFRelease(identityResult);
            return fail("read installer identity certificate", status);
        }
        if ([certificateSHA1(certificate) isEqualToString:expectedSHA1]) {
            selectedIdentity = (__bridge SecIdentityRef)value;
            ++matches;
        }
        CFRelease(certificate);
    }
    if (matches != 1) {
        CFRelease(identityResult);
        fprintf(stderr, "expected exactly one installer identity matching the recorded fingerprint\n");
        return 2;
    }

    SecKeyRef privateKey = NULL;
    status = SecIdentityCopyPrivateKey(selectedIdentity, &privateKey);
    if (status != errSecSuccess) {
        CFRelease(identityResult);
        return fail("read matching private key reference", status);
    }
    CFDictionaryRef keyAttributes = SecKeyCopyAttributes(privateKey);
    CFDataRef applicationLabel = keyAttributes == NULL ? NULL :
        (CFDataRef)CFDictionaryGetValue(keyAttributes, kSecAttrApplicationLabel);
    if (applicationLabel == NULL) {
        if (keyAttributes != NULL) CFRelease(keyAttributes);
        CFRelease(privateKey);
        CFRelease(identityResult);
        fprintf(stderr, "matching private key has no application-label attribute\n");
        return 2;
    }

    NSDictionary *keyQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassKey,
        (__bridge id)kSecUseKeychain: (__bridge id)keychain,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPrivate,
        (__bridge id)kSecAttrApplicationLabel: (__bridge id)applicationLabel,
        (__bridge id)kSecReturnPersistentRef: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
    };
    CFTypeRef keyResult = NULL;
    status = SecItemCopyMatching((__bridge CFDictionaryRef)keyQuery, &keyResult);
    if (status != errSecSuccess) {
        CFRelease(keyAttributes);
        CFRelease(privateKey);
        CFRelease(identityResult);
        return fail("find exact installer private key", status);
    }
    NSArray *references = CFGetTypeID(keyResult) == CFArrayGetTypeID()
        ? (__bridge NSArray *)keyResult : @[(__bridge id)keyResult];
    if (references.count != 1 || CFGetTypeID((__bridge CFTypeRef)references.firstObject) != CFDataGetTypeID()) {
        CFRelease(keyResult);
        CFRelease(keyAttributes);
        CFRelease(privateKey);
        CFRelease(identityResult);
        fprintf(stderr, "expected exactly one private key for the installer identity\n");
        return 2;
    }

    SecKeychainItemRef keyItem = NULL;
    status = SecKeychainItemCopyFromPersistentReference(
        (__bridge CFDataRef)references.firstObject, &keyItem);
    CFRelease(keyResult);
    CFRelease(keyAttributes);
    CFRelease(privateKey);
    CFRelease(identityResult);
    if (status != errSecSuccess) return fail("open exact installer key item", status);

    SecAccessRef access = NULL;
    status = SecKeychainItemCopyAccess(keyItem, &access);
    if (status != errSecSuccess) {
        CFRelease(keyItem);
        return fail("read installer key access controls", status);
    }
    CFArrayRef aclList = NULL;
    status = SecAccessCopyACLList(access, &aclList);
    if (status != errSecSuccess) {
        CFRelease(access);
        CFRelease(keyItem);
        return fail("read installer key ACL entries", status);
    }

    SecTrustedApplicationRef productsign = NULL;
    status = SecTrustedApplicationCreateFromPath("/usr/bin/productsign", &productsign);
    if (status != errSecSuccess) {
        CFRelease(aclList);
        CFRelease(access);
        CFRelease(keyItem);
        return fail("identify productsign executable", status);
    }
    CFDataRef productsignData = NULL;
    status = SecTrustedApplicationCopyData(productsign, &productsignData);
    if (status != errSecSuccess) {
        CFRelease(productsign);
        CFRelease(aclList);
        CFRelease(access);
        CFRelease(keyItem);
        return fail("identify productsign executable", status);
    }

    NSUInteger signingACLCount = 0;
    NSUInteger additions = 0;
    for (CFIndex index = 0; index < CFArrayGetCount(aclList); ++index) {
        SecACLRef acl = (SecACLRef)CFArrayGetValueAtIndex(aclList, index);
        BOOL signingACL = isSigningACL(acl, &status);
        if (status != errSecSuccess) break;
        if (!signingACL) continue;
        ++signingACLCount;

        CFArrayRef applications = NULL;
        CFStringRef description = NULL;
        SecKeychainPromptSelector promptSelector = 0;
        status = SecACLCopyContents(acl, &applications, &description, &promptSelector);
        if (status != errSecSuccess) break;
        BOOL alreadyTrusted = containsTrustedApplication(applications, productsignData, &status);
        if (status != errSecSuccess) {
            if (applications != NULL) CFRelease(applications);
            if (description != NULL) CFRelease(description);
            break;
        }
        if (!alreadyTrusted && applications != NULL) {
            CFMutableArrayRef updated = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, applications);
            CFArrayAppendValue(updated, productsign);
            status = SecACLSetContents(acl, updated, description, promptSelector);
            CFRelease(updated);
        }
        if (!alreadyTrusted && applications == NULL) {
            // A NULL list means this signing ACL already allows any executable.
            alreadyTrusted = YES;
        }
        if (!alreadyTrusted && status == errSecSuccess) ++additions;
        if (applications != NULL) CFRelease(applications);
        if (description != NULL) CFRelease(description);
        if (status != errSecSuccess) break;
    }
    if (status == errSecSuccess && signingACLCount == 0) status = errSecAuthFailed;
    if (status == errSecSuccess && additions > 0) status = SecKeychainItemSetAccess(keyItem, access);
    if (status != errSecSuccess) {
        CFRelease(productsignData);
        CFRelease(productsign);
        CFRelease(aclList);
        CFRelease(access);
        CFRelease(keyItem);
        return fail("add productsign to installer key signing ACL", status);
    }

    // Read back the target key ACL and verify productsign is trusted for signing.
    SecAccessRef verifiedAccess = NULL;
    status = SecKeychainItemCopyAccess(keyItem, &verifiedAccess);
    CFArrayRef verifiedACLs = NULL;
    if (status == errSecSuccess) status = SecAccessCopyACLList(verifiedAccess, &verifiedACLs);
    BOOL verified = NO;
    if (status == errSecSuccess) {
        for (CFIndex index = 0; index < CFArrayGetCount(verifiedACLs); ++index) {
            SecACLRef acl = (SecACLRef)CFArrayGetValueAtIndex(verifiedACLs, index);
            if (!isSigningACL(acl, &status)) continue;
            CFArrayRef applications = NULL;
            CFStringRef description = NULL;
            SecKeychainPromptSelector promptSelector = 0;
            status = SecACLCopyContents(acl, &applications, &description, &promptSelector);
            if (status == errSecSuccess &&
                containsTrustedApplication(applications, productsignData, &status)) verified = YES;
            if (applications != NULL) CFRelease(applications);
            if (description != NULL) CFRelease(description);
            if (verified || status != errSecSuccess) break;
        }
    }

    if (verifiedACLs != NULL) CFRelease(verifiedACLs);
    if (verifiedAccess != NULL) CFRelease(verifiedAccess);
    CFRelease(productsignData);
    CFRelease(productsign);
    CFRelease(aclList);
    CFRelease(access);
    CFRelease(keyItem);
    if (status != errSecSuccess) return fail("verify installer key ACL", status);
    if (!verified) {
        fprintf(stderr, "productsign is not trusted by the installer key signing ACL\n");
        return 2;
    }
    printf("{\"certificate_sha1\":\"%s\",\"matching_private_keys\":1,\"signing_acl_entries\":%lu,\"productsign_acl_additions\":%lu,\"productsign_trusted_for_signing\":true}\n",
           expectedSHA1.UTF8String, (unsigned long)signingACLCount, (unsigned long)additions);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3 || strlen(argv[2]) != CC_SHA1_DIGEST_LENGTH * 2) {
            fprintf(stderr, "usage: repair_macos_installer_key_acl KEYCHAIN CERTIFICATE_SHA1\n");
            return 2;
        }
        NSString *expectedSHA1 = [[NSString stringWithUTF8String:argv[2]] uppercaseString];
        SecKeychainRef keychain = NULL;
        OSStatus status = SecKeychainOpen(argv[1], &keychain);
        if (status != errSecSuccess) return fail("open dedicated signing keychain", status);
        int result = repair(keychain, expectedSHA1);
        CFRelease(keychain);
        return result;
    }
}
