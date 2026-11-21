import {test} from 'node:test';
import assert from 'node:assert/strict';
import {comicTurns,comicLocator,parseComicLocator} from '../../../assets/reader/comic-layout.js';
const pages=Array.from({length:7},()=>({width:800,height:1200}));
const indices=turns=>turns.map(t=>t.map(p=>p.index));
test('cover, odd final page and right-to-left pairing',()=>{
    assert.deepEqual(indices(comicTurns(pages,{spread:'double'},1200,800)),[[0],[1,2],[3,4],[5,6]]);
    assert.deepEqual(indices(comicTurns(pages,{spread:'double',direction:'rtl',coverAlone:false},1200,800)),[[1,0],[3,2],[5,4],[6]]);
});
test('wide images are never squeezed into half of a spread',()=>{
    const copy=pages.map(p=>({...p}));copy[2]={width:1600,height:1000};
    assert.deepEqual(indices(comicTurns(copy,{spread:'double'},1200,800)),[[0],[1],[2],[3,4],[5,6]]);
});
test('split halves follow reading order and disable pairing',()=>{
    const p=[{width:1600,height:1000}];
    assert.deepEqual(comicTurns(p,{spread:'double',splitWide:true,direction:'rtl'},1200,800),[[{index:0,half:1}],[{index:0,half:0}]]);
    assert.deepEqual(comicTurns(p,{splitWide:true},1200,800),[[{index:0,half:0}],[{index:0,half:1}]]);
});
test('automatic mode fits device and webtoon keeps physical images intact',()=>{
    assert.equal(comicTurns(pages,{spread:'auto'},600,900).length,7);
    assert.equal(comicTurns(pages,{spread:'auto'},1200,900).length,4);
    assert.equal(comicTurns(pages,{spread:'double',comicMode:'webtoon',splitWide:true},1200,900).length,7);
});
test('stable locators preserve halves, webtoon offset and legacy bookmarks',()=>{
    assert.deepEqual(parseComicLocator(comicLocator(2,1,.4)),{index:2,half:1,offset:.4});
    assert.deepEqual(parseComicLocator('epubcfi(/6/8!/4/2)'),{index:3,offset:0});
    assert.deepEqual(parseComicLocator('broken',4),{index:4,offset:0});
    assert.equal(parseComicLocator(comicLocator(2,undefined,10)).offset,1);
});

test('an issue correction isolates either half and repairs the following pairs in reading order',()=>{
    const narrow=Array.from({length:8},()=>({width:600,height:900}));
    const pairs=settings=>comicTurns(narrow,{spread:'double',...settings},1200,800).map(turn=>turn.map(p=>p.index));
    assert.deepEqual(pairs({soloPages:[2]}),[[0],[1],[2],[3,4],[5,6],[7]]);
    assert.deepEqual(pairs({direction:'rtl',soloPages:[1,4]}),[[0],[1],[3,2],[4],[6,5],[7]]);
    assert.deepEqual(pairs({soloPages:[]}),[[0],[1,2],[3,4],[5,6],[7]]);
});
test('guided frames retain authored order in RTL, survive rotation and preserve old locators',()=>{
    const pages=[{frames:[[300,0,600,600],[0,0,300,600]]},{}];
    for(const [w,h] of [[320,640],[640,320]]) {
        assert.deepEqual(comicTurns(pages,{comicMode:'panels',direction:'rtl'},w,h),
            [[{index:0,panel:0}],[{index:0,panel:1}],[{index:1}]]);
    }
    assert.equal(parseComicLocator(comicLocator(0,undefined,0,1)).panel,1);
    assert.equal(parseComicLocator(comicLocator(0,undefined)).panel,undefined);
});

test('panel bounds clip to known image size and reject empty frames',async()=>{
    const {comicPanelBounds}=await import('../../../assets/reader/comic-layout.js');
    assert.deepEqual(comicPanelBounds({width:800,height:1000,frames:[[-5,10,900,1200]]},0),[0,10,800,1000]);
    assert.equal(comicPanelBounds({width:800,height:1000,frames:[[900,0,1000,500]]},0),null);
    assert.equal(comicPanelBounds({frames:[[0,0,0,500]]},0),null);
});

test('guided mode skips out-of-image frames and keeps unmarked pages readable',()=>{
    assert.deepEqual(comicTurns([{width:100,height:100,frames:[[110,0,120,20],[0,0,20,20]]},{}],
        {comicMode:'panels'},320,640),[[{index:0,panel:1}],[{index:1}]]);
});

test('narrow book posture pairs RTL pages while preserving single mode and physical locators',()=>{
    const settings={spread:'auto',direction:'rtl',foldPane:320,foldGap:18};
    const open=comicTurns(pages,settings,658,800);
    assert.deepEqual(indices(open),[[0],[2,1],[4,3],[6,5]]);
    const locator=comicLocator(3,undefined);
    const closed=comicTurns(pages,{...settings,foldPane:0},320,800);
    assert.equal(closed.find(t=>t.some(p=>p.index===parseComicLocator(locator).index))[0].index,3);
    assert.equal(comicTurns(pages,{...settings,spread:'single'},658,800).length,7);
});
