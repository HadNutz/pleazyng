import { Entry, Library } from './Library';

@Component
export struct LibraryBrowser {
  openMedia: (url: string, headers: Record<string, string>) => void = () => {};
  @State private address: string = '';
  @State private user: string = '';
  @State private credential: string = '';
  @State private plex: boolean = false;
  @State private connected: boolean = false;
  @State private busy: boolean = false;
  @State private entries: Entry[] = [];
  @State private hasMore: boolean = false;
  @State private depth: number = 0;
  @State private message: string = '';
  private server?: Library;
  private generation: number = 0;
  private parents: string[] = [];
  private start: number = 0;

  aboutToDisappear(): void { this.generation++; this.server = undefined; }

  private disconnect(): void {
    this.generation++;
    this.server = undefined;
    this.busy = false;
    this.connected = false;
    this.credential = '';
    this.entries = [];
    this.parents = [];
    this.depth = 0;
    this.hasMore = false;
    this.message = '';
  }

  private async load(parent: string, start: number, ancestors: string[]): Promise<void> {
    const server = this.server;
    if (!server) return;
    const generation = ++this.generation;
    this.busy = true;
    this.message = '';
    try {
      const page = await server.browse(parent, start);
      if (generation !== this.generation) return;
      this.entries = start ? this.entries.concat(page.entries) : page.entries;
      this.parents = ancestors;
      this.depth = ancestors.length;
      this.start = start;
      this.hasMore = page.more;
      this.connected = true;
    } catch (_) { if (generation === this.generation) this.message = 'Unable to read this library.'; }
    finally { if (generation === this.generation) this.busy = false; }
  }

  private async connect(): Promise<void> {
    const generation = ++this.generation;
    this.busy = true;
    this.message = '';
    try {
      const server = new Library(this.address, this.plex);
      await server.login(this.user, this.credential);
      if (generation !== this.generation) return;
      this.server = server;
      await this.load('', 0, []);
      if (this.connected) this.credential = '';
    } catch (_) { if (generation === this.generation) this.message = 'Unable to sign in to this server.'; }
    finally { if (generation === this.generation) this.busy = false; }
  }

  build() {
    Column({ space: 6 }) {
      if (!this.connected) {
        Button(this.plex ? 'Plex' : 'Jellyfin / Emby').enabled(!this.busy).onClick(() => { this.plex = !this.plex; this.credential = ''; })
        TextInput({ text: this.address, placeholder: 'Server address' }).onChange((s: string) => this.address = s)
        if (!this.plex) { TextInput({ text: this.user, placeholder: 'Username' }).onChange((s: string) => this.user = s) }
        TextInput({ text: this.credential, placeholder: this.plex ? 'Plex access token' : 'Password' })
          .type(InputType.Password).onChange((s: string) => this.credential = s)
        Button('Connect').enabled(!this.busy).onClick(() => this.connect())
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          if (this.depth > 0) {
            Button('Back').enabled(!this.busy).onClick(() => {
              const next = this.parents.slice(0, -1);
              this.load(next[next.length - 1] ?? '', 0, next);
            })
          }
          Button('Disconnect').onClick(() => this.disconnect())
        }
        ForEach(this.entries, (item: Entry) => {
          Button(item.title).enabled(!this.busy).onClick(() => {
            if (item.playable && this.server) this.openMedia(this.server.mediaUrl(item), this.server.headers());
            else this.load(item.id, 0, this.parents.concat([item.id]));
          })
        }, (item: Entry) => item.id)
        if (this.hasMore) {
          Button('More').enabled(!this.busy).onClick(() => this.load(this.parents[this.depth - 1] ?? '', this.start + 60, this.parents))
        }
      }
      if (this.message) { Text(this.message).fontColor(Color.White) }
    }.width('100%')
  }
}
