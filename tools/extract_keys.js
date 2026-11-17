/*
 * extract_keys.js — Frida script for one-time key extraction from Meta AI app
 *
 * This script hooks SecItemAdd in the Meta AI iOS app to intercept the
 * RSA-2048 private key and bootstrap ticket that the app stores in the
 * Keychain during glasses pairing. These values are needed once to let
 * OpenGlass authenticate independently.
 *
 * Usage:
 *   1. Install the patched (Frida-injected) Meta AI IPA via AltStore
 *   2. Open the patched app on your iPhone
 *   3. From your Mac (USB connected):
 *        frida -U "Meta AI" -l extract_keys.js
 *   4. In the app, unpair your glasses and re-pair them
 *   5. The script prints the RSA key and bootstrap ticket as hex
 *   6. Copy the hex values into OpenGlass Settings > Import Identity
 *   7. Delete the Meta AI app — you won't need it again
 */

'use strict';

const RSA_KEY_TAG = 'com.facebook.orca';  // Meta's keychain tag pattern for RSA keys
const TICKET_PATTERN = /bootstrap|ticket|credential/i;

let capturedKey = null;
let capturedTicket = null;

function hexDump(data, length) {
    const bytes = [];
    for (let i = 0; i < length; i++) {
        bytes.push(('0' + (data.add(i).readU8()).toString(16)).slice(-2));
    }
    return bytes.join('');
}

function parseCFDictionary(dict) {
    const result = {};
    const count = ObjC.classes.NSDictionary['- count'].call(dict);
    const keys = ObjC.classes.NSDictionary['- allKeys'].call(dict);
    for (let i = 0; i < count; i++) {
        const key = keys.objectAtIndex_(i);
        const value = ObjC.classes.NSDictionary['- objectForKey:'].call(dict, key);
        result[key.toString()] = value;
    }
    return result;
}

// Hook SecItemAdd to intercept keychain writes
Interceptor.attach(Module.findExportByName(null, 'SecItemAdd'), {
    onEnter: function (args) {
        this.attrs = new ObjC.Object(args[0]);
    },
    onLeave: function (retval) {
        try {
            const attrs = parseCFDictionary(this.attrs);
            const klass = attrs['class'] ? attrs['class'].toString() : '';
            const account = attrs['acct'] ? attrs['acct'].toString() : '';
            const service = attrs['svce'] ? attrs['svce'].toString() : '';
            const tag = attrs['atag'] ? attrs['atag'].toString() : '';
            const label = attrs['labl'] ? attrs['labl'].toString() : '';
            const data = attrs['v_Data'];

            const context = `class=${klass} account=${account} service=${service} tag=${tag} label=${label}`;

            // Look for RSA private key data
            if (klass.includes('key') || tag.includes('rsa') || tag.includes('RSA') ||
                account.includes('rsa') || account.includes('private') ||
                label.includes('private') || label.includes('Private')) {

                if (data) {
                    const nsdata = new ObjC.Object(data);
                    const length = nsdata.length();
                    const bytes = nsdata.bytes();

                    if (length >= 256) {  // RSA-2048 key is at least 256 bytes
                        capturedKey = hexDump(bytes, length);
                        console.log('\n========================================');
                        console.log('  RSA PRIVATE KEY CAPTURED');
                        console.log('  Context: ' + context);
                        console.log('  Length: ' + length + ' bytes');
                        console.log('========================================');
                        console.log('RSA_KEY_HEX=' + capturedKey);
                        console.log('========================================\n');
                    }
                }
            }

            // Look for bootstrap ticket / credential data
            if (account.match(TICKET_PATTERN) || service.match(TICKET_PATTERN) ||
                label.match(TICKET_PATTERN) || tag.match(TICKET_PATTERN)) {

                if (data) {
                    const nsdata = new ObjC.Object(data);
                    const length = nsdata.length();
                    const bytes = nsdata.bytes();

                    capturedTicket = hexDump(bytes, length);
                    console.log('\n========================================');
                    console.log('  BOOTSTRAP TICKET CAPTURED');
                    console.log('  Context: ' + context);
                    console.log('  Length: ' + length + ' bytes');
                    console.log('========================================');
                    console.log('TICKET_HEX=' + capturedTicket);
                    console.log('========================================\n');
                }
            }

            // Also log all keychain writes for debugging
            if (data) {
                const nsdata = new ObjC.Object(data);
                console.log('[SecItemAdd] ' + context + ' (' + nsdata.length() + ' bytes)');
            }

        } catch (e) {
            // Ignore parse errors on non-NSDictionary args
        }
    }
});

// Also hook SecItemUpdate for keys that get updated rather than added
Interceptor.attach(Module.findExportByName(null, 'SecItemUpdate'), {
    onEnter: function (args) {
        this.query = new ObjC.Object(args[0]);
        this.update = new ObjC.Object(args[1]);
    },
    onLeave: function (retval) {
        try {
            const updateAttrs = parseCFDictionary(this.update);
            const data = updateAttrs['v_Data'];
            if (data) {
                const nsdata = new ObjC.Object(data);
                const length = nsdata.length();
                console.log('[SecItemUpdate] data updated (' + length + ' bytes)');

                if (length >= 256) {
                    const bytes = nsdata.bytes();
                    const hex = hexDump(bytes, length);
                    console.log('\n========================================');
                    console.log('  POSSIBLE KEY UPDATE');
                    console.log('  Length: ' + length + ' bytes');
                    console.log('========================================');
                    console.log('UPDATE_HEX=' + hex);
                    console.log('========================================\n');
                }
            }
        } catch (e) {
            // Ignore
        }
    }
});

console.log('\n[*] OpenGlass key extraction script loaded');
console.log('[*] Waiting for keychain writes...');
console.log('[*] Unpair and re-pair your glasses in the Meta AI app to trigger extraction.');
console.log('[*] Look for RSA_KEY_HEX and TICKET_HEX in the output.\n');
