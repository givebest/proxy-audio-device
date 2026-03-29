#include <vector>
#include <CoreAudio/CoreAudio.h>
#import "WindowDelegate.h"
#include "AudioDevice.h"
#include "ProxyAudioDevice.h"

int onDevicesChanged(AudioObjectID inObjectID,
                     UInt32 inNumberAddresses,
                     const AudioObjectPropertyAddress *inAddresses,
                     void *inClientData);

@implementation WindowDelegate {
    std::vector<AudioDeviceID> currentDeviceList;
    int initializationAttemptInterval;
    int selectedDevice; // 1 or 2
}

- (void)awakeFromNib {
    selectedDevice = 1;
    self.deviceNameTextField.stringValue = NSLocalizedString(@"< Loading... >", nil);
    self.deviceNameTextField.enabled = NO;
    self.outputDeviceComboBox.enabled = NO;
    self.bufferSizeComboBox.enabled = NO;
    self.proxiedDeviceIsActiveRadioButton.enabled = NO;
    self.userIsActiveRadioButton.enabled = NO;
    self.alwaysRadioButton.enabled = NO;
    initializationAttemptInterval = 3;
    [self keepTryingToInitializeUntilSuccess];
}

- (void)keepTryingToInitializeUntilSuccess {
    bool success = [self initialize];

    if (!success) {
        NSLog(@"NB: failed to initialize, will try again in a sec...");
        [NSTimer scheduledTimerWithTimeInterval:initializationAttemptInterval target:self selector:@selector(keepTryingToInitializeUntilSuccess) userInfo:nil repeats:NO];
        initializationAttemptInterval += 2;
    }
}

- (CFStringRef)currentBoxUID {
    return selectedDevice == 2 ? CFSTR(kBox2_UID) : CFSTR(kBox_UID);
}

- (bool)initialize {
    if (![self setCurrentProcessAsConfigurator]) {
        return false;
    }

    self.deviceNameTextField.stringValue = [self currentDeviceName];

    if (![self proxyAudioDeviceAvailable]) {
        return true;
    }

    if (![self refreshOutputDevices]) {
        return false;
    }

    if (![self setupListenerForCurrentAudioDevices]) {
        return false;
    }

    [self.bufferSizeComboBox selectItemWithObjectValue:[self currentOutputDeviceBufferFrameSize]];
    self.deviceNameTextField.enabled = YES;
    self.outputDeviceComboBox.enabled = YES;
    self.bufferSizeComboBox.enabled = YES;
    self.proxiedDeviceIsActiveRadioButton.enabled = YES;
    self.userIsActiveRadioButton.enabled = YES;
    self.alwaysRadioButton.enabled = YES;

    ProxyAudioDevice::ActiveCondition condition = [self currentOutputDeviceActiveCondition];

    if (condition == ProxyAudioDevice::ActiveCondition::proxiedDeviceActive) {
        self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOn;
        self.userIsActiveRadioButton.state = NSControlStateValueOff;
        self.alwaysRadioButton.state = NSControlStateValueOff;
    } else if (condition == ProxyAudioDevice::ActiveCondition::userActive) {
        self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
        self.userIsActiveRadioButton.state = NSControlStateValueOn;
        self.alwaysRadioButton.state = NSControlStateValueOff;
    } else {
        self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
        self.userIsActiveRadioButton.state = NSControlStateValueOff;
        self.alwaysRadioButton.state = NSControlStateValueOn;
    }

    return true;
}

- (bool)setCurrentProcessAsConfigurator {
    // Register with both boxes so both devices recognize this process as configurator
    AudioDeviceID box1 = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDeviceID box2 = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox2_UID));

    if (box1 == kAudioObjectUnknown && box2 == kAudioObjectUnknown) {
        NSLog(@"Error: unable to find proxy audio device");
        return true;
    }

    if (box1 != kAudioObjectUnknown) {
        if (!AudioDevice::setIdentifyValue(box1, getpid())) {
            NSLog(@"Error: unable to set current process as configurator for device 1");
            return false;
        }
    }

    if (box2 != kAudioObjectUnknown) {
        if (!AudioDevice::setIdentifyValue(box2, getpid())) {
            NSLog(@"Error: unable to set current process as configurator for device 2");
            return false;
        }
    }

    return true;
}

int onDevicesChanged(AudioObjectID inObjectID,
                     UInt32 inNumberAddresses,
                     const AudioObjectPropertyAddress *inAddresses,
                     void *inClientData) {
#pragma unused(inObjectID, inNumberAddresses, inAddresses)
    dispatch_async(dispatch_get_main_queue(), ^{
        WindowDelegate *delegate = (__bridge WindowDelegate *)inClientData;
        [delegate refreshOutputDevices];
    });

    return noErr;
}

- (bool)setupListenerForCurrentAudioDevices {
    AudioObjectPropertyAddress listenerPropertyAddress = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    OSStatus err =
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &listenerPropertyAddress, &onDevicesChanged, (__bridge_retained void *)self);

    if (err != noErr) {
        NSLog(@"Error: could not set up listener for audio devices changing");
        return false;
    }

    return true;
}

- (bool)proxyAudioDeviceAvailable {
    return AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID)) != kAudioObjectUnknown ||
           AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox2_UID)) != kAudioObjectUnknown;
}

- (NSString *)currentDeviceName {
    AudioDeviceID box = AudioDevice::audioDeviceIDForBoxUID([self currentBoxUID]);
    if (box == kAudioObjectUnknown) {
        return NSLocalizedString(@"< Proxy Audio Device not found >", nil);
    }
    AudioDevice::setIdentifyValue(box, -((SInt32)ProxyAudioDevice::ConfigType::deviceName));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(box);

    return result ? result : NSLocalizedString(@"< Proxy Audio Device not found >", nil);
}

- (IBAction)deviceNameEntered:(id)sender {
#pragma unused(sender)
    NSString *newName = [self.deviceNameTextField.stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (newName.length == 0) {
        self.deviceNameTextField.stringValue = [self currentDeviceName];
        return;
    }

    AudioDeviceID box = AudioDevice::audioDeviceIDForBoxUID([self currentBoxUID]);
    if (box == kAudioObjectUnknown) return;
    AudioDevice::setObjectName(box,
                               (__bridge_retained CFStringRef)[NSString stringWithFormat:@"deviceName=%@", newName]);
}

- (AudioDeviceID)currentOutputDevice {
    AudioDeviceID box = AudioDevice::audioDeviceIDForBoxUID([self currentBoxUID]);
    if (box == kAudioObjectUnknown) return kAudioObjectUnknown;
    AudioDevice::setIdentifyValue(box, -((SInt32)ProxyAudioDevice::ConfigType::outputDevice));
    NSString *outputDeviceUID = (__bridge_transfer NSString *)AudioDevice::copyObjectName(box);

    return AudioDevice::audioDeviceIDForDeviceUID((__bridge_retained CFStringRef)outputDeviceUID);
}

- (bool)refreshOutputDevices {
    bool success = false;
    [self.outputDeviceComboBox removeAllItems];
    currentDeviceList = AudioDevice::devicesWithOutputCapabilitiesThatAreNotProxyAudioDevice();
    AudioDeviceID outputDevice = [self currentOutputDevice];

    for (unsigned int i = 0; i < currentDeviceList.size(); ++i) {
        NSString *deviceName = (__bridge_transfer NSString *)AudioDevice::copyObjectName(currentDeviceList[i]);

        if (!deviceName) {
            NSLog(@"Note: got null device name for audio device with device with ID: %d", currentDeviceList[i]);
            continue;
        }

        [self.outputDeviceComboBox addItemWithObjectValue:deviceName];

        if (outputDevice == currentDeviceList[i]) {
            [self.outputDeviceComboBox selectItemAtIndex:i];
        }

        success = true;
    }

    if (!success) {
        NSLog(@"Error: failed to get any information about current output devices!");
    }

    return success;
}

- (IBAction)outputDeviceSelected:(id)sender {
#pragma unused(sender)
    unsigned long index = (unsigned long)self.outputDeviceComboBox.indexOfSelectedItem;

    if (index < 0 || index >= currentDeviceList.size()) {
        NSLog(@"Error: got invalid selection index when trying to set output device");
        return;
    }

    NSString *uid = (__bridge_transfer NSString *)AudioDevice::copyDeviceUID(currentDeviceList[index]);

    if (!uid) {
        NSLog(@"Error: got invalid UID when trying to set output device");
        return;
    }

    AudioDeviceID box = AudioDevice::audioDeviceIDForBoxUID([self currentBoxUID]);
    if (box == kAudioObjectUnknown) return;
    AudioDevice::setObjectName(box,
                               (__bridge_retained CFStringRef)[NSString stringWithFormat:@"outputDevice=%@", uid]);
}

- (NSString *)currentOutputDeviceBufferFrameSize {
    AudioDeviceID box = AudioDevice::audioDeviceIDForBoxUID([self currentBoxUID]);
    if (box == kAudioObjectUnknown) return @"";
    AudioDevice::setIdentifyValue(box, -((SInt32)ProxyAudioDevice::ConfigType::outputDeviceBufferFrameSize));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(box);

    return result ? result : @"";
}

- (IBAction)outputDeviceBufferFrameSizeSelected:(id)sender {
#pragma unused(sender)
    NSString *newBufferFrameSizeString = self.bufferSizeComboBox.objectValueOfSelectedItem;

    if (!newBufferFrameSizeString) {
        NSLog(@"Error: got invalid buffer frame size value");
        return;
    }

    AudioDeviceID box = AudioDevice::audioDeviceIDForBoxUID([self currentBoxUID]);
    if (box == kAudioObjectUnknown) return;
    AudioDevice::setObjectName(
        box,
        (__bridge_retained CFStringRef)
            [NSString stringWithFormat:@"outputDeviceBufferFrameSize=%@", newBufferFrameSizeString]);
}

- (ProxyAudioDevice::ActiveCondition)currentOutputDeviceActiveCondition {
    AudioDeviceID box = AudioDevice::audioDeviceIDForBoxUID([self currentBoxUID]);
    if (box == kAudioObjectUnknown) return ProxyAudioDevice::ActiveCondition::userActive;
    AudioDevice::setIdentifyValue(box, -((SInt32)ProxyAudioDevice::ConfigType::deviceActiveCondition));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(box);

    return (ProxyAudioDevice::ActiveCondition)[result intValue];
}

- (void)setCurrentOutputDeviceActiveCondition:(ProxyAudioDevice::ActiveCondition)condition {
    AudioDeviceID box = AudioDevice::audioDeviceIDForBoxUID([self currentBoxUID]);
    if (box == kAudioObjectUnknown) return;
    AudioDevice::setObjectName(
        box,
        (__bridge_retained CFStringRef)
            [NSString stringWithFormat:@"outputDeviceActiveCondition=%d", condition]);
}

- (IBAction)proxiedDeviceIsActiveConditionSelected:(id)sender {
    #pragma unused(sender)
    self.alwaysRadioButton.state = NSControlStateValueOff;
    self.userIsActiveRadioButton.state = NSControlStateValueOff;
    [self setCurrentOutputDeviceActiveCondition:ProxyAudioDevice::ActiveCondition::proxiedDeviceActive];
}

- (IBAction)userIsActiveConditionSelected:(id)sender {
    #pragma unused(sender)
    self.alwaysRadioButton.state = NSControlStateValueOff;
    self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
    [self setCurrentOutputDeviceActiveCondition:ProxyAudioDevice::ActiveCondition::userActive];
}

- (IBAction)alwaysConditionSelected:(id)sender {
    #pragma unused(sender)
    self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
    self.userIsActiveRadioButton.state = NSControlStateValueOff;
    [self setCurrentOutputDeviceActiveCondition:ProxyAudioDevice::ActiveCondition::always];
}

- (IBAction)deviceSelectorChanged:(id)sender {
#pragma unused(sender)
    selectedDevice = (int)self.deviceSelector.selectedSegment + 1;
    [self reloadCurrentDeviceUI];
}

- (void)reloadCurrentDeviceUI {
    self.deviceNameTextField.stringValue = [self currentDeviceName];

    AudioDeviceID box = AudioDevice::audioDeviceIDForBoxUID([self currentBoxUID]);
    if (box == kAudioObjectUnknown) {
        self.deviceNameTextField.enabled = NO;
        self.outputDeviceComboBox.enabled = NO;
        self.bufferSizeComboBox.enabled = NO;
        self.proxiedDeviceIsActiveRadioButton.enabled = NO;
        self.userIsActiveRadioButton.enabled = NO;
        self.alwaysRadioButton.enabled = NO;
        return;
    }

    [self refreshOutputDevices];
    [self.bufferSizeComboBox selectItemWithObjectValue:[self currentOutputDeviceBufferFrameSize]];

    self.deviceNameTextField.enabled = YES;
    self.outputDeviceComboBox.enabled = YES;
    self.bufferSizeComboBox.enabled = YES;
    self.proxiedDeviceIsActiveRadioButton.enabled = YES;
    self.userIsActiveRadioButton.enabled = YES;
    self.alwaysRadioButton.enabled = YES;

    ProxyAudioDevice::ActiveCondition condition = [self currentOutputDeviceActiveCondition];

    if (condition == ProxyAudioDevice::ActiveCondition::proxiedDeviceActive) {
        self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOn;
        self.userIsActiveRadioButton.state = NSControlStateValueOff;
        self.alwaysRadioButton.state = NSControlStateValueOff;
    } else if (condition == ProxyAudioDevice::ActiveCondition::userActive) {
        self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
        self.userIsActiveRadioButton.state = NSControlStateValueOn;
        self.alwaysRadioButton.state = NSControlStateValueOff;
    } else {
        self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
        self.userIsActiveRadioButton.state = NSControlStateValueOff;
        self.alwaysRadioButton.state = NSControlStateValueOn;
    }
}

@end
