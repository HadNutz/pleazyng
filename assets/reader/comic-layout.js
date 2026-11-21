// Pure physical-page planning; neither layout nor reading direction changes identity.
export const isWide = page => page.doublePage || (page.width > 0 && page.height > 0 && page.width > page.height);
export function comicTurns(pages, settings, width, height) {
    if (settings.comicMode === 'panels') {
        return pages.flatMap((page,index) => {
            const frames = (page.frames ?? []).flatMap((_,panel) => comicPanelBounds(page,panel) ? [[{index,panel}]] : []);
            return frames.length ? frames : [[{index}]];
        });
    }
    const double = settings.comicMode !== 'webtoon' && !settings.splitWide &&
        (settings.spread === 'double' || (settings.spread === 'auto' && (settings.foldPane > 0 || (width >= 900 && width > height))));
    const solo = new Set(settings.soloPages ?? []);
    const turns = [];
    for (let i = 0; i < pages.length; i++) {
        const page = pages[i];
        if (settings.splitWide && settings.comicMode !== 'webtoon' && isWide(page)) {
            const halves = settings.direction === 'rtl' ? [1, 0] : [0, 1];
            turns.push(...halves.map(half => [{index: i, half}]));
        } else if (double && !(i === 0 && settings.coverAlone !== false) &&
            !solo.has(i) && !solo.has(i + 1) && !isWide(page) && i + 1 < pages.length && !isWide(pages[i + 1])) {
            const pair = [{index: i}, {index: ++i}];
            turns.push(settings.direction === 'rtl' ? pair.reverse() : pair);
        } else turns.push([{index: i}]);
    }
    return turns;
}
export function comicLocator(index, half, offset = 0, panel) {
    return `plezy-comic:${index}:${half ?? -1}:${Math.min(1, Math.max(0, offset))}${Number.isInteger(panel) ? `:p${panel}` : ''}`;
}
export function parseComicLocator(value, fallback = 0) {
    const match = /^plezy-comic:(\d+):(-1|0|1):([\d.]+)(?::p(\d+))?$/.exec(value ?? '');
    if (match) return {...(match[4] === undefined ? {} : {panel:Number(match[4])}), index: Number(match[1]), half: match[2] === '-1' ? undefined : Number(match[2]), offset: Math.min(1, Math.max(0, Number(match[3]) || 0))};
    // Foliate CBZ CFIs encoded spine index as an even step: /6/2, /6/4, ...
    const legacy = /^epubcfi\(\/6\/(\d+)/.exec(value ?? '');
    return {index: legacy ? Math.max(0, Math.floor(Number(legacy[1]) / 2) - 1) : fallback, offset: 0};
}

// Reject empty/out-of-image frames, while retaining their original sequence.
// Bounds only describe a zoom viewport; the page image is never rewritten.
export function comicPanelBounds(page, panel) {
    const value = page.frames?.[panel];
    if (!Array.isArray(value) || value.length !== 4 || !value.every(Number.isFinite)) return null;
    const [x,y,right,bottom] = value;
    const bounds = [Math.max(0,x),Math.max(0,y),
        Math.min(page.width ?? right,right),Math.min(page.height ?? bottom,bottom)];
    return bounds[2] > bounds[0] && bounds[3] > bounds[1] ? bounds : null;
}
