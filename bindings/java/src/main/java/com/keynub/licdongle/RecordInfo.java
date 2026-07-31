package com.keynub.licdongle;

/** A record name and size, from {@link Session#listRecords()}. */
public record RecordInfo(String name, long size) {
}
