import { OvaleQueue } from "./Queue";
let _pairs = pairs;
let _setmetatable = setmetatable;
let _error = error;
let _ipairs = ipairs;
let _tonumber = tonumber;
let _type = type;
let wrap = coroutine.wrap;
let strfind = string.find;
let strsub = string.sub;
let append = table.insert;
const assert_arg = function(idx, val, tp) {
    if (_type(val) != tp) {
        _error("argument " + idx + " must be " + tp, 2);
    }
}

export type Tokenizer = (tok:string) => [string, string];

export interface LexerFilter {
    space?: Tokenizer;
    comments?: Tokenizer;
}


export type TokenizerDefinition = { [1]: string, [2]: Tokenizer };


export class OvaleLexer {
    typeQueue = new OvaleQueue<string>("typeQueue");
    tokenQueue = new OvaleQueue<string>("tokenQueue");
    endOfStream = undefined;
    iterator: LuaIterable<[string, string]>;
    
    constructor(public name: string, stream: string, matches: LuaArray<TokenizerDefinition>, filter?: LexerFilter) {
        this.iterator = this.scan(stream, matches, filter);
    }

    finished: boolean;
    private scan(s: string, matches: LuaArray<TokenizerDefinition>, filter?:LexerFilter) {
        let me = this;

        const lex = function*():IterableIterator<[string, string]> {
            if (s == '') {
                return;
            }
            let sz = lualength(s);
            let idx = 1;
            while (true) {
                for (const [_, m] of _ipairs(matches)) {
                    const pat = m[1];
                    const fun = m[2];
                    const [i1, i2] = strfind(s, pat, idx)
                    if (i1) {
                        const tok = strsub(s, i1, i2);
                        idx = i2 + 1;
                        if (!filter || (fun !== filter.comments && fun !== filter.space)) {
                            me.finished = idx > sz;
                            const [res1, res2] = fun(tok);
                            yield [res1, res2];
                        }
                        break;
                    }
                }
            }
        }
        return wrap(lex);
    }

    Release() {
        for (const [key] of _pairs(this)) {
            this[key] = undefined;
        }
    }
    Consume(index?: number):[string, string] {
        index = index || 1;
        let tokenType: string, token: string;
        while (index > 0 && this.typeQueue.Size() > 0) {
            tokenType = this.typeQueue.RemoveFront();
            token = this.tokenQueue.RemoveFront();
            if (!tokenType) {
                break;
            }
            index = index - 1;
        }
        while (index > 0) {
            [tokenType, token] = this.iterator();
            if (!tokenType) {
                break;
            }
            index = index - 1;
        }
        return [tokenType, token];
    }
    Peek(index?: number):[string, string] {
        index = index || 1;
        let tokenType:string, token: string;
        while (index > this.typeQueue.Size()) {
            if (this.endOfStream) {
                break;
            } else {
                [tokenType, token] = this.iterator();
                if (!tokenType) {
                    this.endOfStream = true;
                    break;
                }
                this.typeQueue.InsertBack(tokenType);
                this.tokenQueue.InsertBack(token);
            }
        }
        if (index <= this.typeQueue.Size()) {
            tokenType = this.typeQueue.At(index);
            token = this.tokenQueue.At(index);
        }
        return [tokenType, token];
    }
}
