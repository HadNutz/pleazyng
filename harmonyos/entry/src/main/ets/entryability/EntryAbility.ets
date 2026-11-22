import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Player');
  }

  onBackground(): void {
    AppStorage.setOrCreate('background', true);
  }

  onForeground(): void {
    AppStorage.setOrCreate('background', false);
  }
}
