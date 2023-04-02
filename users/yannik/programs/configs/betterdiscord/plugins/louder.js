(function() {

    // The following utility function are taken from EnhancedDiscord, developed by 
    // joe27g <https://github.com/joe27g>, and licensed under an MIT License.
    // All credit goes to joe27g for the breadth of the work regarding accessing
    // webpack modules at runtime.
    //
    // ---
    // MIT License
    //
    // Copyright (c) 2019 joe27g
    //
    // Permission is hereby granted, free of charge, to any person obtaining a copy
    // of this software and associated documentation files (the "Software"), to deal
    // in the Software without restriction, including without limitation the rights
    // to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    // copies of the Software, and to permit persons to whom the Software is
    // furnished to do so, subject to the following conditions:
    //
    // The above copyright notice and this permission notice shall be included in all
    // copies or substantial portions of the Software.
    //
    // THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    // IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    // FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    // AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    // LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    // OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    // SOFTWARE.
    //
    // ---
    //
    // Taken from dom_shit.js, lines 79-149, commit 8795de5f80608f4647668fcd5c3a5a7d508f350b
    // https://github.com/joe27g/EnhancedDiscord/blob/8795de5f80608f4647668fcd5c3a5a7d508f350b/dom_shit.js#L79
    //
    // ---
    //
    // このスクリプトはdavejbax氏のdiscord.jsを元に作成されています。
    // https://gist.github.com/davejbax/42abae54865f2ba1e3c649c7949fbbe1
    //
    // DiscordのアップデートによりUserVolumeGroupが取得できなくなったため、該当部分を削除。
    // 最低限の動作をするように改変しています。
    //
    // 注意点としてDiscordの言語設定が「日本語」か「English」の場合にのみ動作します。(未検証)
    // また、このスクリプトを使用して起こったいかなる事態に関しても責任をおいません。予めご了承下さい。
    //
    // ここを改変することで最大音量の変更ができます。
    let maxVolume = 500;
    // < BEGIN EnhancedDiscord CODE >
    window.req = webpackJsonp.push([[], {
        '__extra_id__': (module, exports, req) => module.exports = req
    }, [['__extra_id__']]]);
    delete req.m['__extra_id__'];
    delete req.c['__extra_id__'];

    window.findModule = (module, silent) => {
        for (let i in req.c) {
            if (req.c.hasOwnProperty(i)) {
                let m = req.c[i].exports;
                if (m && m.__esModule && m.default && m.default[module] !== undefined)
                    return m.default;
                if (m && m[module] !== undefined)
                    return m;
            }
        }
        if (!silent) c.warn(`Could not find module ${module}.`, {name: 'Modules', color: 'black'});
        return null;
    };
    window.findModules = (module) => {
        let mods = [];
        for (let i in req.c) {
            if (req.c.hasOwnProperty(i)) {
                let m = req.c[i].exports;
                if (m && m.__esModule && m.default && m.default[module] !== undefined)
                    mods.push(m.default);
                if (m && m[module] !== undefined)
                    mods.push(m);
            }
        }
        return mods;
    };
    window.findRawModule = (module, silent) => {
        for (let i in req.c) {
            if (req.c.hasOwnProperty(i)) {
                let m = req.c[i].exports;
                if (m && m.__esModule && m.default && m.default[module] !== undefined)
                    return req.c[i];
                if (m && m[module] !== undefined)
                    return req.c[i];
            }
        }
        if (!silent) c.warn(`Could not find module ${module}.`, {name: 'Modules', color: 'black'});
        return null;
    };

    window.findReactComponent = (name) => {
        const named = findModules('displayName');
        return named.find(m => m.displayName === name);
    };

    window.monkeyPatch = function(what, methodName, newFunc) {
        if (!what || typeof what !== 'object')
            return c.error(`Could not patch ${methodName} - Invalid module passed!`, {name: 'Modules', color: 'black'});
        const displayName = what.displayName || what.name || what.constructor.displayName || what.constructor.name;
        const origMethod = what[methodName];
        const cancel = () => {
            what[methodName] = origMethod;
            console.log(`%c[EnhancedDiscord] %c[Modules]`, 'color: red;', `color: black;`, `Unpatched ${methodName} in module:`, what);
            return true;
        };
        what[methodName] = function() {
            const data = {
                thisObject: this,
                methodArguments: arguments,
                //cancelPatch: cancel,
                originalMethod: origMethod,
                callOriginalMethod: () => data.returnValue = data.originalMethod.apply(data.thisObject, data.methodArguments)
            };
            return newFunc(data);
        };
        what[methodName].__monkeyPatched = true;
        what[methodName].displayName = 'patched ' + (what[methodName].displayName || methodName);
        what[methodName].unpatch = cancel;
        console.log(`%c[EnhancedDiscord] %c[Modules]`, 'color: red;', `color: black;`, `Patched ${methodName} in module:`, what);
        return true;
    };
    // < END EnhancedDiscord CODE >

    // Find the relevant components
    const Slider = findReactComponent('Slider');

    // Unpatch render methods if already patched (this allows re-pasting)
    if (Slider.prototype.render.__monkeyPatched) {
        Slider.prototype.render.unpatch();
    }

    // We patch the Slider component, because we need to change it's max value;
    // we can change this prop and re-render, but the state of the component does NOT
    // change until it is re-created entirely. We therefore change the state ourselves
    // on render (without re-invoking render) so that state.max and state.range are
    // set correctly to the props (as if the component had been re-created).
    monkeyPatch(Slider.prototype, 'render', (data) => {
        // Check whether there's a discrepancy between prop max and state max
        // 表示名が「ユーザーの音量」もしくは「User volume」のスライダーにのみ変更を適用
        if(data.thisObject && (data.thisObject.props['aria-label'] === 'ユーザーの音量' ||
                data.thisObject.props['aria-label'] === 'User volume')){
            let props = Object.assign({}, data.thisObject.props);
            props.maxValue = maxVolume;
            data.thisObject.props = props;
            let state = Object.assign({}, data.thisObject.state);
            if(!data.thisObject.state.active)state.value = state.initialValueProp;
            state.max = maxVolume;
            state.range = state.max;
            data.thisObject.state = state;
        }
        
        return data.callOriginalMethod();
    });

})();
