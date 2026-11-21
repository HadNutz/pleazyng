import { common } from '@kit.AbilityKit';
import { display, PiPWindow, window } from '@kit.ArkUI';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { Pane, splitPanes } from './Pane';
import { LibraryBrowser } from './LibraryBrowser';

@Entry
@Component
struct Player {
  private surface: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private player?: media.AVPlayer;
  private pip?: PiPWindow.PiPController;
  private host?: window.Window;
  private file?: fs.File;
  private generation: number = 0;
  private alive: boolean = false;
  private releasing: Promise<void> = Promise.resolve();
  private insidePip: boolean = false;
  private surfaceWidth: number = 16;
  private surfaceHeight: number = 9;
  private originX: number = 0;
  private originY: number = 0;
  private viewWidth: number = 0;
  private viewHeight: number = 0;
  @StorageProp('background') @Watch('backgroundChanged') private inBackground: boolean = false;
  @State picture: Pane = new Pane(0, 0, 1, 1);
  @State transport: Pane = new Pane(0, 0, 1, 1);
  @State address: string = '';
  @State state: string = 'idle';
  @State status: string = '';
  @State duration: number = 0;
  @State elapsedMs: number = 0;
  @State showLibrary: boolean = false;
  @State canPip: boolean = false;

  private contextForWindow(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private updateLayout = (): void => {
    const ui = this.getUIContext();
    const view = new Pane(0, 0, this.viewWidth, this.viewHeight);
    if (view.width < 1 || view.height < 1) return;
    const gaps: Pane[] = [];
    try {
      if (this.host && display.isFoldable()) {
        const status = display.getFoldStatus();
        const properties = this.host.getWindowProperties();
        const region = display.getCurrentFoldCreaseRegion();
        if (region.displayId === (properties.displayId ?? display.getDefaultDisplaySync().id)) {
          for (let i = 0; i < region.creaseRects.length; i++) {
            // Dual-hinge status encodes the first hinge in units and the second in tens.
            const half = status === 3 || (status > 10 && (i === 0 ? status % 10 === 3 : Math.floor(status / 10) === 2));
            if (!half) continue;
            const r = region.creaseRects[i];
            gaps.push(new Pane(ui.px2vp(r.left - properties.windowRect.left) - this.originX,
              ui.px2vp(r.top - properties.windowRect.top) - this.originY, ui.px2vp(r.width), ui.px2vp(r.height)));
          }
        }
      }
    } catch (_) { /* A rectangular window is sufficient on non-foldable displays. */ }
    const panes = splitPanes(view, gaps);
    if (panes.length > 1) {
      this.picture = panes[0];
      this.transport = panes[panes.length - 1];
    } else {
      const height = Math.max(1, Math.min(view.height * 0.65, view.height - Math.min(140, view.height / 2)));
      this.picture = new Pane(0, 0, view.width, height);
      this.transport = new Pane(0, height, view.width, view.height - height);
    }
  };

  aboutToAppear(): void {
    this.alive = true;
    try { this.canPip = PiPWindow.isPiPEnabled(); } catch (_) { this.canPip = false; }
    window.getLastWindow(this.contextForWindow()).then((win: window.Window) => {
      if (!this.alive) return;
      this.host = win;
      win.on('windowRectChange', this.updateLayout);
      this.updateLayout();
    }).catch(() => {});
    try {
      if (display.isFoldable()) {
        display.on('foldStatusChange', this.updateLayout);
        display.on('foldDisplayModeChange', this.updateLayout);
      }
    } catch (_) { this.updateLayout(); }
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.generation++;
    try { this.host?.off('windowRectChange', this.updateLayout); } catch (_) {}
    try { display.off('foldStatusChange', this.updateLayout); } catch (_) {}
    try { display.off('foldDisplayModeChange', this.updateLayout); } catch (_) {}
    if (this.pip) {
      this.pip.off('stateChange');
      this.pip.off('controlEvent');
      if (this.insidePip) this.pip.stopPiP().catch(() => {});
      this.pip = undefined;
    }
    this.releasePlayer();
  }

  private backgroundChanged(): void {
    if (this.inBackground && !this.insidePip && this.player?.state === 'playing') {
      this.player.pause().catch(() => {});
    }
  }

  private async releasePlayer(): Promise<void> {
    const old = this.player;
    const file = this.file;
    this.player = undefined;
    this.file = undefined;
    this.releasing = this.releasing.then(async (): Promise<void> => {
      try { if (old) await old.release(); } catch (_) {}
      try { if (file) fs.closeSync(file); } catch (_) {}
    });
    await this.releasing;
  }

  private async chooseFile(): Promise<void> {
    const generation = this.generation;
    try {
      const list = await new picker.DocumentViewPicker(this.contextForWindow()).select({ maxSelectNumber: 1 });
      if (this.alive && generation === this.generation && list.length === 1) await this.open(list[0], true);
    } catch (_) { this.status = 'File selection ended.'; }
  }

  private async open(source: string, local: boolean, headers: Record<string, string> = {}): Promise<void> {
    if (!local && !/^https?:\/\/[^\s/]+/i.test(source)) {
      this.status = 'Enter an HTTP or HTTPS media address.';
      return;
    }
    if (!this.surfaceId) return;
    const generation = ++this.generation;
    try {
      await this.releasePlayer();
      if (!this.alive || generation !== this.generation) return;
      this.state = 'idle';
      this.duration = 0;
      this.elapsedMs = 0;
      this.status = '';
      const player = await media.createAVPlayer();
      if (!this.alive || generation !== this.generation) { await player.release(); return; }
      this.player = player;
      player.on('stateChange', async (state: string) => {
        if (this.player !== player) return;
        this.state = state;
        try {
          if (state === 'initialized') {
            player.surfaceId = this.surfaceId;
            await player.prepare();
          } else if (state === 'prepared') {
            this.duration = Math.max(0, player.duration);
            if (!this.inBackground || this.insidePip) await player.play();
          } else if (state === 'playing' || state === 'paused') {
            this.pip?.updatePiPControlStatus(PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
              state === 'playing' ? PiPWindow.PiPControlStatus.PLAY : PiPWindow.PiPControlStatus.PAUSE);
          }
        } catch (_) { if (this.player === player) this.status = 'Playback could not start.'; }
      });
      player.on('videoSizeChange', (width: number, height: number) => {
        if (this.player !== player || width <= 0 || height <= 0) return;
        this.surfaceWidth = width;
        this.surfaceHeight = height;
        try { this.pip?.updateContentSize(width, height); } catch (_) {}
      });
      player.on('timeUpdate', (time: number) => { if (this.player === player) this.elapsedMs = time; });
      player.on('error', () => { if (this.player === player) this.status = 'This source could not be played.'; });
      if (local) {
        const file = fs.openSync(source, fs.OpenMode.READ_ONLY);
        this.file = file;
        player.fdSrc = { fd: file.fd };
      } else {
        let hdr = false;
        try {
          const id = this.host?.getWindowProperties().displayId;
          const screen = id === undefined ? display.getDefaultDisplaySync() : display.getDisplayByIdSync(id);
          hdr = screen.hdrFormats.some((format: number) => format >= 1 && format <= 3);
        } catch (_) { /* Use the default SDR variant if capabilities are unavailable. */ }
        const stream = media.createMediaSourceWithUrl(source, headers);
        await player.setMediaSource(stream, { preferredHdr: hdr });
      }
    } catch (_) {
      if (generation === this.generation) {
        this.status = 'Unable to open media.';
        this.state = 'idle';
        await this.releasePlayer();
      }
    }
  }

  private async toggle(): Promise<void> {
    const player = this.player;
    if (!player) return;
    try {
      if (player.state === 'playing') await player.pause();
      else if (['paused', 'prepared', 'completed'].includes(player.state)) await player.play();
    } catch (_) { this.status = 'Transport is unavailable.'; }
  }

  private async enterPip(): Promise<void> {
    if (this.insidePip || !this.player) return;
    this.insidePip = true;
    try {
      if (!this.pip) {
        const controller = await PiPWindow.create({ context: this.contextForWindow(), componentController: this.surface,
          templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY, contentWidth: this.surfaceWidth, contentHeight: this.surfaceHeight });
        if (!this.alive) return;
        this.pip = controller;
        controller.on('stateChange', (state: PiPWindow.PiPState) => {
          if (state === PiPWindow.PiPState.STOPPED) { this.insidePip = false; this.backgroundChanged(); }
        });
        controller.on('controlEvent', (event: PiPWindow.ControlEventParam) => {
          if (event.controlType === PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE &&
              ((event.status === PiPWindow.PiPControlStatus.PLAY && this.state !== 'playing') ||
               (event.status === PiPWindow.PiPControlStatus.PAUSE && this.state === 'playing'))) this.toggle();
        });
      }
      await this.pip.startPiP();
    } catch (_) { this.insidePip = false; this.status = 'Picture in picture is unavailable on this display.'; }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      XComponent({ id: 'pleazyng-picture', type: XComponentType.SURFACE, controller: this.surface })
        .width(this.picture.width).height(this.picture.height).position({ x: this.picture.left, y: this.picture.top })
        .onLoad(() => { this.surfaceId = this.surface.getXComponentSurfaceId(); })
      Scroll() {
        Column({ space: 8 }) {
          TextInput({ text: this.address, placeholder: 'Media URL' }).onChange((s: string) => this.address = s)
          Flex({ wrap: FlexWrap.Wrap }) {
            Button('Open URL').onClick(() => this.open(this.address.trim(), false))
            Button('Open file').onClick(() => this.chooseFile())
            Button('Libraries').onClick(() => this.showLibrary = !this.showLibrary)
            Button(this.state === 'playing' ? 'Pause' : 'Play').onClick(() => this.toggle())
            if (this.canPip) { Button('Picture in picture').onClick(() => this.enterPip()) }
          }
          if (this.duration > 0) {
            Slider({ value: this.elapsedMs, min: 0, max: this.duration }).onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.player?.seek(Math.floor(value));
            })
          }
          LibraryBrowser({ openMedia: (url: string, headers: Record<string, string>) => {
            this.open(url, false, headers);
          } }).visibility(this.showLibrary ? Visibility.Visible : Visibility.None)
          if (this.status) { Text(this.status).fontColor(Color.White) }
        }.padding(12).width('100%')
      }.width(this.transport.width).height(this.transport.height).position({ x: this.transport.left, y: this.transport.top })
    }.backgroundColor(Color.Black).width('100%').height('100%')
    .onAreaChange((_: Area, area: Area) => {
      this.viewWidth = Number(area.width); this.viewHeight = Number(area.height);
      this.originX = Number(area.globalPosition.x); this.originY = Number(area.globalPosition.y);
      this.updateLayout();
    })
  }
}
