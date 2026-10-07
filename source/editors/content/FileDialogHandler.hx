package editors.content;

import openfl.net.FileReference;
import openfl.events.Event;
import openfl.events.IOErrorEvent;
import flash.net.FileFilter;

import haxe.Exception;
#if !js
import sys.io.File;
import sys.FileSystem;
#end
import lime.ui.*;
import mohong.TraceManager;

import flixel.FlxBasic;
import flixel.FlxG;
import backend.ui.PsychUIButton;
import editors.content.Prompt.BasePrompt;
import Language;

#if android
import android.Tools as AndroidTools;
import android.Permissions;
import android.callback.CallBack;
#end

@:access(openfl.net.FileReference)

enum abstract FileDialogType(String)
{
    var OPEN = "open";
    var SAVE = "save";
    var OPEN_DIRECTORY = "openDirectory";
}

class FileDialogHandler extends FlxBasic
{
    var _fileRef:FileReferenceCustom;
    var _dialogMode:FileDialogType = OPEN;
    
    #if android
    var _pendingAndroidRequest:Int = -1;
    var _pendingMimeType:String;
    var _pendingFileName:String;
    var _pendingDataToSave:String;
    #end
    
    public function new()
    {
        _fileRef = new FileReferenceCustom();
        _fileRef.addEventListener(Event.CANCEL, onCancelFn);
        _fileRef.addEventListener(IOErrorEvent.IO_ERROR, onErrorFn);
        
        #if android
        CallBack.init();
        CallBack.onActivityResult.add(onAndroidActivityResult);
        #end
        
        super();
    }

    public var onComplete:Void->Void;
    public var onCancel:Void->Void;
    public var onError:Void->Void;

    var _currentEvent:openfl.events.Event->Void;

    public function save(?fileName:String = '', ?dataToSave:String = '', ?onComplete:Void->Void, ?onCancel:Void->Void, ?onError:Void->Void)
    {
        // 上一次对话框操作尚未结束时，这里曾经直接 throw——调用方（saveChart 等）
        // 都跑在 lime 主循环里，没有 try/catch 能接住它，结果就是整进程崩溃。
        // 改为按“出错”走完回调流程：复位状态、记日志、触发 onError。
        if(!completed)
        {
            // 上一次对话框操作尚未结束时，这里曾经直接 throw——调用方（saveChart 等）
            // 都跑在 lime 主循环里，没有 try/catch 能接住它，结果就是整进程崩溃。
            // 改为就地消化：复位 completed 解除卡死，并回调本次请求的 onError
            // （形参在此处遮蔽同名字段）告知“请求被拒”，绝不向主循环抛异常。
            TraceManager.error('trace.editor.fileDialogBusy', 'New dialog requested while a previous one is still pending.');
            completed = true;
            var cb:Void->Void = onError;
            _startUp(null, null, null);
            completed = true;
            if(cb != null) cb();
            return;
        }

        this._dialogMode = SAVE;
        _startUp(onComplete, onCancel, onError);

        #if android
        _pendingFileName = fileName;
        _pendingDataToSave = dataToSave;
        
        if (fileName != null && fileName.length > 0 && !fileName.contains('.'))
            _pendingFileName += '.json';
        
        var mimeType = getMimeTypeFromFileName(_pendingFileName);
        _pendingMimeType = mimeType;
        
        AndroidTools.createDocument(mimeType, _pendingFileName, AndroidTools.REQUEST_CODE_CREATE_DOCUMENT);
        _pendingAndroidRequest = AndroidTools.REQUEST_CODE_CREATE_DOCUMENT;
        #elseif ios
        // OpenFL's FileReference.save() is a no-op on iOS (only desktop and
        // HTML5 implement it), so the native "save" dialog simply never fires
        // its callbacks. Instead, write directly into the app's Documents
        // directory (SUtil.getStorageDirectory() on iOS returns
        // LimeSystem.documentsDirectory).
        if(fileName == null || fileName.length == 0)
            fileName = 'chart.json';
        if(!fileName.contains('.'))
            fileName += '.json';

        var dir:String = SUtil.getStorageDirectory();
        if(dir != null && dir.length > 0 && !dir.endsWith('/'))
            dir += '/';
        var fullPath:String = dir + fileName;
        try {
            if(!FileSystem.exists(dir))
                FileSystem.createDirectory(dir);
            sys.io.File.saveContent(fullPath, dataToSave);
            this.path = fullPath;
            this.completed = true;
            TraceManager.info('trace.editor.fileSaved', 'Saved file to: {}', [fullPath]);
            if(onComplete != null) onComplete();
        } catch(e:Dynamic) {
            this.completed = true;
            TraceManager.error('trace.editor.fileSaveError', 'Save failed: {}', [Std.string(e)]);
            if(onError != null) onError();
        }
        #else
        removeEvents();
        _currentEvent = onSaveComplete;
        _fileRef.addEventListener(Event.SELECT, _currentEvent);
        
        if(fileName != null && fileName.length > 0 && !fileName.contains('.'))
            fileName += '.json';
        
        _fileRef.save(dataToSave, fileName);
        #end
    }

    public function open(?defaultName:String = null, ?title:String = null, ?filter:Array<FileFilter> = null, ?onComplete:Void->Void, ?onCancel:Void->Void, ?onError:Void->Void)
    {
        // 上一次对话框操作尚未结束时，这里曾经直接 throw——调用方（saveChart 等）
        // 都跑在 lime 主循环里，没有 try/catch 能接住它，结果就是整进程崩溃。
        // 改为按“出错”走完回调流程：复位状态、记日志、触发 onError。
        if(!completed)
        {
            // 上一次对话框操作尚未结束时，这里曾经直接 throw——调用方（saveChart 等）
            // 都跑在 lime 主循环里，没有 try/catch 能接住它，结果就是整进程崩溃。
            // 改为就地消化：复位 completed 解除卡死，并回调本次请求的 onError
            // （形参在此处遮蔽同名字段）告知“请求被拒”，绝不向主循环抛异常。
            TraceManager.error('trace.editor.fileDialogBusy', 'New dialog requested while a previous one is still pending.');
            completed = true;
            var cb:Void->Void = onError;
            _startUp(null, null, null);
            completed = true;
            if(cb != null) cb();
            return;
        }

        this._dialogMode = OPEN;
        _startUp(onComplete, onCancel, onError);
        
        #if android
        var mimeTypes = "*/*";
        if (filter != null && filter.length > 0) {
            var exts = [];
            for (f in filter) {
                var parts = f.extension.split(';');
                for (p in parts) {
                    var ext = p.trim();
                    if (ext.startsWith('*.')) ext = ext.substr(2);
                    exts.push(ext);
                }
            }
            // Convert ALL extensions to MIME types; join with '|' for Android
            if (exts.length > 0) {
                var mimeList:Array<String> = [];
                for (ext in exts) {
                    var mapped = getMimeTypeFromFileName('x.' + ext);
                    if (mapped != null && mapped != "application/octet-stream") {
                        if (!mimeList.contains(mapped))
                            mimeList.push(mapped);
                    } else {
                        // Unknown extension — fall back to */* to show all files
                        mimeList = [];
                        break;
                    }
                }
                if (mimeList.length > 0)
                    mimeTypes = mimeList.join('|');
                else
                    mimeTypes = "*/*";
            } else {
                mimeTypes = "*/*";
            }
        }
        
        _pendingMimeType = mimeTypes;
        AndroidTools.openDocument(mimeTypes, AndroidTools.REQUEST_CODE_OPEN_DOCUMENT);
        _pendingAndroidRequest = AndroidTools.REQUEST_CODE_OPEN_DOCUMENT;
        #elseif ios
        // OpenFL's FileReference.browse() is a no-op on iOS. Scan the app's
        // Documents directory and let the player pick from an in-game list.
        var dir:String = SUtil.getStorageDirectory();
        if(dir != null && dir.length > 0 && !dir.endsWith('/'))
            dir += '/';

        var exts:Array<String> = ['.json', '.osu', '.mc', '.osz', '.mcz'];
        var files:Array<String> = [];
        try {
            if(FileSystem.exists(dir))
            {
                for(file in FileSystem.readDirectory(dir))
                {
                    var lower:String = file.toLowerCase();
                    for(ext in exts)
                    {
                        if(lower.endsWith(ext))
                        {
                            files.push(dir + file);
                            break;
                        }
                    }
                }
            }
        } catch(e:Dynamic) {}

        if(files.length == 1)
        {
            var found:String = files[0];
            this.path = found;
            this.data = sys.io.File.getContent(found);
            this.completed = true;
            TraceManager.info('trace.editor.fileLoaded', 'Loaded file from: {}', [found]);
            if(onComplete != null) onComplete();
        }
        else if(files.length > 1)
        {
            // Multiple charts in Documents: show an in-game picker.
            var sorted:Array<String> = files.copy();
            sorted.sort(function(a, b) return (a.toLowerCase() < b.toLowerCase()) ? -1 : 1);

            var picker:BasePrompt = new BasePrompt(
                460,
                100 + Math.min(sorted.length, 8) * 40 + 60,
                Language.get('fileDialog_ios_pick', 'Choose a chart from Documents...'),
                function(state:BasePrompt)
                {
                    var btnY:Float = state.bg.y + 50;
                    var shown:Int = 0;
                    for(f in sorted)
                    {
                        if(shown >= 8) break;
                        var fname:String = f.substr(f.lastIndexOf('/') + 1);
                        var btn:PsychUIButton = new PsychUIButton(state.bg.x + 40, btnY, fname, function()
                        {
                            state.close();
                            var picked:String = f;
                            this.path = picked;
                            this.data = sys.io.File.getContent(picked);
                            this.completed = true;
                            TraceManager.info('trace.editor.fileLoaded', 'Loaded file from: {}', [picked]);
                            if(onComplete != null) onComplete();
                        }, 380, 30);
                        btn.cameras = state.cameras;
                        state.add(btn);
                        btnY += 40;
                        shown++;
                    }
                });
            picker.showCloseButton = true;
            var st:Dynamic = FlxG.state;
            if(st != null && Reflect.hasField(st, 'openSubState'))
                st.openSubState(picker);
            else
            {
                this.completed = true;
                if(onCancel != null) onCancel();
            }
        }
        else
        {
            this.completed = true;
            if(onCancel != null) onCancel();
        }
        #else
        removeEvents();
        _currentEvent = onLoadComplete;
        _fileRef.addEventListener(Event.SELECT, _currentEvent);
        
        #if sys
        if(filter == null) filter = [new FileFilter('JSON', 'json')];
        _fileRef.browse(filter);
        #end
        #end
    }

    public function openDirectory(?title:String = null, ?onComplete:Void->Void, ?onCancel:Void->Void, ?onError:Void->Void)
    {
        // 上一次对话框操作尚未结束时，这里曾经直接 throw——调用方（saveChart 等）
        // 都跑在 lime 主循环里，没有 try/catch 能接住它，结果就是整进程崩溃。
        // 改为按“出错”走完回调流程：复位状态、记日志、触发 onError。
        if(!completed)
        {
            // 上一次对话框操作尚未结束时，这里曾经直接 throw——调用方（saveChart 等）
            // 都跑在 lime 主循环里，没有 try/catch 能接住它，结果就是整进程崩溃。
            // 改为就地消化：复位 completed 解除卡死，并回调本次请求的 onError
            // （形参在此处遮蔽同名字段）告知“请求被拒”，绝不向主循环抛异常。
            TraceManager.error('trace.editor.fileDialogBusy', 'New dialog requested while a previous one is still pending.');
            completed = true;
            var cb:Void->Void = onError;
            _startUp(null, null, null);
            completed = true;
            if(cb != null) cb();
            return;
        }

        this._dialogMode = OPEN_DIRECTORY;
        _startUp(onComplete, onCancel, onError);

        #if android
        // Android doesn't directly support directory picking through SAF like this,
        // but we can use OPEN_DOCUMENT_TREE. Since that's not in the current AndroidTools,
        // we fall back to opening any file type.
        _pendingMimeType = "*/*";
        AndroidTools.openDocument("*/*", AndroidTools.REQUEST_CODE_OPEN_DOCUMENT);
        _pendingAndroidRequest = AndroidTools.REQUEST_CODE_OPEN_DOCUMENT;
        #else
        removeEvents();
        _currentEvent = onLoadDirectoryComplete;
        _fileRef.addEventListener(Event.SELECT, _currentEvent);
        
        #if sys
        _fileRef.browse();
        #end
        #end
    }

    #if android
    function onAndroidActivityResult(data:Dynamic)
    {
        if (_pendingAndroidRequest == -1) return;
        
        if (data == null || data.resultCode == 0) {
            // User cancelled
            _pendingAndroidRequest = -1;
            this.completed = true;
            if (onCancel != null) onCancel();
            return;
        }
        
        var uri:String = data.uri;
        if (uri == null) {
            _pendingAndroidRequest = -1;
            this.completed = true;
            if (onError != null) onError();
            return;
        }
        
        switch (_dialogMode) {
            case SAVE:
                if (_pendingAndroidRequest == AndroidTools.REQUEST_CODE_CREATE_DOCUMENT) {
                    // Write the data to the URI
                    var success = AndroidTools.writeTextToUri(uri, _pendingDataToSave);
                    if (success) {
                        AndroidTools.persistUriPermission(uri);
                        this.path = uri;
                        this.completed = true;
                        TraceManager.info('trace.editor.fileSaved', 'Saved file to: {}', [uri]);
                        if (onComplete != null) onComplete();
                    } else {
                        this.completed = true;
                        if (onError != null) onError();
                    }
                }
                
            case OPEN, OPEN_DIRECTORY:
                if (_pendingAndroidRequest == AndroidTools.REQUEST_CODE_OPEN_DOCUMENT) {
                    // Android SAF returns a content:// URI which sys.io.File
                    // cannot open. Copy it into a local cache path first so
                    // every consumer (chart editor, converter, ...) gets a
                    // real filesystem path - this also preserves the original
                    // file extension (.osz/.mcz/.osu/.mc/json) which callers
                    // rely on for format detection.
                    var localPath:String = AndroidTools.copyUriToFile(uri, SUtil.getStorageDirectory() + 'converted/tmp/pick');
                    if (localPath == null || localPath.length == 0) {
                        this.completed = true;
                        if (onError != null) onError();
                        return;
                    }

                    this.path = localPath;

                    // For text-based formats (json / osu / mc / cne) also
                    // expose the decoded content; binary packages (osz/mcz)
                    // are handled via this.path by the callers.
                    var lower:String = localPath.toLowerCase();
                    var isBinary:Bool = lower.endsWith('.osz') || lower.endsWith('.mcz');
                    if (!isBinary) {
                        var content = AndroidTools.readTextFromUri(uri);
                        if (content != null)
                            this.data = content;
                        TraceManager.info('trace.editor.androidLoad',
                            'Android file load: path={} dataLen={} dataHead={}', [
                            localPath,
                            (this.data != null ? this.data.length : -1),
                            (this.data != null && this.data.length > 0 ? this.data.substr(0, 40) : 'NULL')
                        ]);
                    }

                    AndroidTools.persistUriPermission(uri);
                    this.completed = true;
                    TraceManager.info('trace.editor.fileLoaded', 'Loaded file from: {}', [localPath]);
                    if (onComplete != null) onComplete();
                }
        }
        
        _pendingAndroidRequest = -1;
    }
    
    function getMimeTypeFromFileName(fileName:String):String
    {
        if (fileName == null) return "application/octet-stream";
        
        var ext = fileName.split('.').pop().toLowerCase();
        return switch (ext) {
            case 'json': 'application/json';
            case 'txt', 'hx', 'hxml': 'text/plain';
            case 'xml': 'application/xml';
            case 'csv': 'text/csv';
            case 'png': 'image/png';
            case 'jpg', 'jpeg': 'image/jpeg';
            case 'gif': 'image/gif';
            case 'wav': 'audio/wav';
            case 'mp3': 'audio/mpeg';
            case 'ogg': 'audio/ogg';
            case 'mp4': 'video/mp4';
            case 'pdf': 'application/pdf';
            case 'zip': 'application/zip';
            case 'seb': 'application/octet-stream';
            default: 'application/octet-stream';
        }
    }
    #end

    public var data:String;
    public var path:String;
    public var completed:Bool = true;
    
    function onSaveComplete(_)
    {
        @:privateAccess
        this.path = _fileRef._trackSavedPath;
        this.completed = true;
        TraceManager.info('trace.editor.fileSaved', 'Saved file to: {}', [path]);

        removeEvents();
        if(onComplete != null) onComplete();
    }

    function onLoadComplete(_)
    {
        @:privateAccess
        this.path = _fileRef.__path;
        #if sys
        // 读取失败的异常会从 lime 的事件分发里穿出去直接崩溃进程（没有上层
        // try/catch），所以在这里就地捕获并转成 onError 回调。
        try
        {
            this.data = File.getContent(this.path);
        }
        catch(e:Dynamic)
        {
            this.completed = true;
            TraceManager.error('trace.editor.fileLoadError', 'Failed to read file from {}: {}', [path, Std.string(e)]);
            removeEvents();
            if(onError != null) onError();
            return;
        }
        #end
        this.completed = true;
        TraceManager.info('trace.editor.fileLoaded', 'Loaded file from: {}', [path]);

        removeEvents();
        if(onComplete != null) onComplete();
    }

    function onLoadDirectoryComplete(_)
    {
        @:privateAccess
        var p:String = _fileRef.__path;
        #if sys
        // FileReference.browse() opens a *file* picker, not a folder picker. When
        // the user picks a file inside the target folder (or types a file name),
        // treat that file's parent directory as the chosen output directory.
        // Otherwise callers build "dir\file.json\out.json" paths and crash on save.
        if (p != null && p.length > 0 && !FileSystem.isDirectory(p))
        {
            var sep:Int = p.lastIndexOf('/');
            #if windows
            if (sep < 0) sep = p.lastIndexOf('\\');
            #end
            if (sep > 0) p = p.substr(0, sep);
        }
        #end
        this.path = p;
        this.completed = true;
        TraceManager.info('trace.editor.dirLoaded', 'Loaded directory: {}', [path]);

        removeEvents();
        if(onComplete != null) onComplete();
    }

    function onCancelFn(_)
    {
        removeEvents();
        this.completed = true;
        if(onCancel != null) onCancel();
    }

    function onErrorFn(_)
    {
        removeEvents();
        this.completed = true;
        if(onError != null) onError();
    }

    function _startUp(onComplete:Void->Void, onCancel:Void->Void, onError:Void->Void)
    {
        this.onComplete = onComplete;
        this.onCancel = onCancel;
        this.onError = onError;
        this.completed = false;
        this.data = null;
        this.path = null;
        #if android
        _pendingAndroidRequest = -1;
        #end
    }

    function removeEvents()
    {
        if(_currentEvent == null) return;
        _fileRef.removeEventListener(Event.SELECT, _currentEvent);
        _currentEvent = null;
    }

    override function destroy()
    {
        removeEvents();
        #if android
        CallBack.onActivityResult.remove(onAndroidActivityResult);
        #end
        _fileRef = null;
        _currentEvent = null;
        onComplete = null;
        onCancel = null;
        onError = null;
        data = null;
        path = null;
        completed = true;
        super.destroy();
    }
}

class FileReferenceCustom extends FileReference
{
    @:allow(editors.content.FileDialogHandler)
    var _trackSavedPath:String;
    
    override function saveFileDialog_onSelect(path:String):Void
    {
        _trackSavedPath = path;
        super.saveFileDialog_onSelect(path);
    }
}
