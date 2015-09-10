/*
 * Copyright (C) 2015 The 8-Bit Bunch. Licensed under the Apache License, Version 1.1 
 * (the "License"); you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at <http://www.apache.org/licenses/LICENSE-1.1>.
 * Unless required by applicable law or agreed to in writing, software distributed under 
 * the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF 
 * ANY KIND, either express or implied. See the License for the specific language 
 * governing permissions and limitations under the License.
 */
 
package org.badvision.outlaweditor.data;

import java.io.Serializable;
import org.badvision.outlaweditor.data.xml.Tile;

/**
 *
 * @author brobert
 */
public class TileInstance implements Serializable {
    transient Tile tile;
    String tileId;
    public TileInstance(Tile t) {
        tile = t;
        if (t != null) {
            tileId = t.getId();
        }
    }
    
    public Tile getTile() {
        if (tile == null && tileId != null) {
            tile = TilesetUtils.getTileById(tileId);
        }
        return tile;
    }
}
