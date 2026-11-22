import React from 'react';
import {StyleSheet, View} from 'react-native';
import {WebView} from '@amazon-devices/webview';
import {
  useHideSplashScreenCallback,
  usePreventHideSplashScreen,
} from '@amazon-devices/react-native-kepler';

export function App() {
  usePreventHideSplashScreen();
  const hideSplash = useHideSplashScreenCallback();
  return (
    <View style={styles.screen}>
      <WebView
        style={styles.screen}
        source={{uri: 'file:///pkg/assets/index.html'}}
        javaScriptEnabled
        hasTVPreferredFocus
        allowSystemKeyEvents
        allowsDefaultMediaControl
        mediaPlaybackRequiresUserAction={false}
        onLoadEnd={hideSplash}
      />
    </View>
  );
}

const styles = StyleSheet.create({screen: {flex: 1, backgroundColor: '#111419'}});
